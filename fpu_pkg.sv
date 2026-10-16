// IEEE-754 single-precision helpers shared by the FP adder, multiplier, and
// divider, following the RISC-V F-extension rules:
//   * every NaN result is the canonical NaN 0x7fc00000
//   * a signaling NaN operand raises invalid (NV)
//   * tininess is detected after rounding
//   * fflags bit order is {NV, DZ, OF, UF, NX}
//
// Intermediate results use one normalized form:
//   value = sig * 2^(exp - 127 - 26), where sig[26] is the leading one,
//   sig[25:3] are the remaining fraction bits, sig[2] is the guard bit, and
//   sig[1:0] are round/sticky bits (sig[0] holds the OR of everything below).
package fpu_pkg;

    localparam logic [2:0] RM_RNE = 3'd0;  // round to nearest, ties to even
    localparam logic [2:0] RM_RTZ = 3'd1;  // toward zero
    localparam logic [2:0] RM_RDN = 3'd2;  // toward -infinity
    localparam logic [2:0] RM_RUP = 3'd3;  // toward +infinity
    localparam logic [2:0] RM_RMM = 3'd4;  // to nearest, ties away from zero
    localparam logic [2:0] RM_DYN = 3'd7;  // use fcsr.frm

    localparam int FLAG_NV = 4;
    localparam int FLAG_DZ = 3;
    localparam int FLAG_OF = 2;
    localparam int FLAG_UF = 1;
    localparam int FLAG_NX = 0;

    localparam logic [31:0] CANONICAL_NAN = 32'h7fc0_0000;

    function automatic logic is_nan(input logic [31:0] x);
        is_nan = (x[30:23] == 8'hff) && (x[22:0] != 0);
    endfunction

    function automatic logic is_snan(input logic [31:0] x);
        is_snan = is_nan(x) && !x[22];
    endfunction

    function automatic logic is_inf(input logic [31:0] x);
        is_inf = (x[30:23] == 8'hff) && (x[22:0] == 0);
    endfunction

    function automatic logic is_zero(input logic [31:0] x);
        is_zero = (x[30:0] == 0);
    endfunction

    function automatic logic [31:0] signed_inf(input logic sign);
        signed_inf = {sign, 8'hff, 23'b0};
    endfunction

    // Significand with the hidden bit for normals; subnormals use exponent 1
    // and no hidden bit, so value = sig * 2^(exponent - 150) in both cases.
    function automatic logic [23:0] unpack_sig(input logic [31:0] x);
        unpack_sig = {x[30:23] != 0, x[22:0]};
    endfunction

    function automatic int unpack_exp(input logic [31:0] x);
        unpack_exp = (x[30:23] == 0) ? 1 : int'(x[30:23]);
    endfunction

    // Bit position of the most significant one (-1 for zero).
    function automatic int leading_one(input logic [63:0] v);
        leading_one = -1;
        for (int i = 0; i < 64; i++)
            if (v[i]) leading_one = i;
    endfunction

    // Shift a nonzero magnitude whose leading one is at bit `msb` so that it
    // lands on bit 26, folding discarded bits (and sticky_in) into bit 0.
    function automatic logic [26:0] to_sig27(input logic [63:0] v, input int msb, input logic sticky_in);
        logic [63:0] shifted;
        logic sticky;
        sticky = sticky_in;
        if (msb >= 26) begin
            shifted = v >> (msb - 26);
            for (int i = 0; i < 64; i++)
                if (i < msb - 26 && v[i]) sticky = 1'b1;
        end else begin
            shifted = v << (26 - msb);
        end
        to_sig27 = {shifted[26:1], shifted[0] | sticky};
    endfunction

    function automatic logic round_up(input logic sign, input logic lsb, input logic guard,
                                      input logic sticky, input logic [2:0] rm);
        unique case (rm)
            RM_RNE: round_up = guard && (sticky || lsb);
            RM_RTZ: round_up = 1'b0;
            RM_RDN: round_up = sign && (guard || sticky);
            RM_RUP: round_up = !sign && (guard || sticky);
            RM_RMM: round_up = guard;
            default: round_up = 1'b0;
        endcase
    endfunction

    // Round a normalized intermediate (see the header) to single precision.
    // Returns {flags[4:0], result[31:0]}. sig must be nonzero.
    function automatic logic [36:0] round_pack(input logic sign, input int exp,
                                               input logic [26:0] sig, input logic [2:0] rm);
        logic [26:0] s;
        logic [24:0] rounded;
        logic [31:0] result;
        logic [4:0] flags;
        logic tiny, inexact, overflow;
        int shift;
        int e;

        flags = 5'b0;
        overflow = 1'b0;

        // Tininess after rounding: tiny unless rounding with an unbounded
        // exponent range produces a normal number.
        if (exp < 0)
            tiny = 1'b1;
        else if (exp == 0)
            tiny = !(round_up(sign, sig[3], sig[2], |sig[1:0], rm) && (sig[26:3] == 24'hff_ffff));
        else
            tiny = 1'b0;

        // Below the normal range: shift right into subnormal position.
        s = sig;
        e = exp;
        if (exp < 1) begin
            shift = 1 - exp;
            if (shift > 26) begin
                s = {26'b0, |sig};
            end else begin
                s = sig >> shift;
                for (int i = 0; i < 27; i++)
                    if (i < shift && sig[i]) s[0] = 1'b1;
            end
            e = 0;
        end

        inexact = |s[2:0];
        rounded = {1'b0, s[26:3]} + round_up(sign, s[3], s[2], |s[1:0], rm);

        if (e == 0) begin
            // Subnormal (or rounded up into the smallest normal: a carry into
            // bit 23 lands exactly in the exponent field's low bit).
            result = {sign, 7'b0, rounded[23:0]};
        end else begin
            if (rounded[24]) begin
                rounded = rounded >> 1;
                e = e + 1;
            end
            if (e >= 255) begin
                overflow = 1'b1;
                // Overflow returns infinity or the largest finite value,
                // depending on the rounding direction.
                if ((rm == RM_RTZ) || (rm == RM_RDN && !sign) || (rm == RM_RUP && sign))
                    result = {sign, 8'hfe, 23'h7f_ffff};
                else
                    result = signed_inf(sign);
            end else begin
                result = {sign, e[7:0], rounded[22:0]};
            end
        end

        flags[FLAG_OF] = overflow;
        flags[FLAG_NX] = inexact || overflow;
        flags[FLAG_UF] = tiny && inexact;
        round_pack = {flags, result};
    endfunction

endpackage
