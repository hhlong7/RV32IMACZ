# Out-of-context constraints for the core-only synthesis (no board pins).
# 20 ns = 50 MHz, the clock the board wrapper generates. Lower the period to
# see how much faster the core could run, or raise it to find what closes.
create_clock -period 20.000 -name clk [get_ports CLK]
