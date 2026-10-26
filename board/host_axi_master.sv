`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: host_axi_master
// Description:
//   The AXI4-Lite master that drives host_bridge.
//   - On the FPGA: Vivado's JTAG-to-AXI Master IP (jtag_axi_0, created by
//     tools/vivado/build_zybo.tcl), which the Hardware Manager uses to read
//     and write over the board's USB-JTAG cable (tools/vivado/host.tcl).
//   - In simulation: a model with write(addr, data) and read(addr, data)
//     tasks that a testbench calls hierarchically.
//////////////////////////////////////////////////////////////////////////////////
module host_axi_master (
    input  logic        aclk,
    input  logic        aresetn,
    output logic [11:0] m_axi_awaddr,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [11:0] m_axi_araddr,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready
);
`ifdef SYNTHESIS
    logic [31:0] awaddr_full, araddr_full;
    assign m_axi_awaddr = awaddr_full[11:0];
    assign m_axi_araddr = araddr_full[11:0];

    jtag_axi_0 JTAG_AXI (
        .aclk(aclk),
        .aresetn(aresetn),
        .m_axi_awaddr(awaddr_full),
        .m_axi_awprot(),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(araddr_full),
        .m_axi_arprot(),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );
`else
    initial begin
        m_axi_awaddr = '0;
        m_axi_awvalid = 1'b0;
        m_axi_wdata = '0;
        m_axi_wstrb = 4'hF;
        m_axi_wvalid = 1'b0;
        m_axi_bready = 1'b0;
        m_axi_araddr = '0;
        m_axi_arvalid = 1'b0;
        m_axi_rready = 1'b0;
    end

    // Address and data together, then wait for the response.
    task automatic write(input logic [11:0] addr, input logic [31:0] data);
        @(negedge aclk);
        m_axi_awaddr = addr;
        m_axi_wdata = data;
        m_axi_awvalid = 1'b1;
        m_axi_wvalid = 1'b1;
        @(posedge aclk);
        while (!(m_axi_awready && m_axi_wready)) @(posedge aclk);
        @(negedge aclk);
        m_axi_awvalid = 1'b0;
        m_axi_wvalid = 1'b0;
        m_axi_bready = 1'b1;
        @(posedge aclk);
        while (!m_axi_bvalid) @(posedge aclk);
        @(negedge aclk);
        m_axi_bready = 1'b0;
    endtask

    task automatic read(input logic [11:0] addr, output logic [31:0] data);
        @(negedge aclk);
        m_axi_araddr = addr;
        m_axi_arvalid = 1'b1;
        @(posedge aclk);
        while (!m_axi_arready) @(posedge aclk);
        @(negedge aclk);
        m_axi_arvalid = 1'b0;
        m_axi_rready = 1'b1;
        @(posedge aclk);
        while (!m_axi_rvalid) @(posedge aclk);
        data = m_axi_rdata;
        @(negedge aclk);
        m_axi_rready = 1'b0;
    endtask
`endif
endmodule
