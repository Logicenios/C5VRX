# Gowin EDA timing constraints (the nextpnr flow uses ../tangnano20k.sdc).
create_clock -name clk27 -period 37.037 [get_ports {clk27}]
create_clock -name lclk  -period 25.000 [get_ports {link_strobe}]
create_clock -name pclk  -period 13.468 [get_nets {pclk}]
create_clock -name fclk  -period 2.694  [get_nets {fclk}]
# the domains meet only through synchronisers, cdc_bus and async FIFOs
set_clock_groups -asynchronous -group [get_clocks {clk27}] -group [get_clocks {lclk}] -group [get_clocks {pclk fclk}]
# full list of failing setup endpoints (the default report shows only 25 paths)
report_timing -setup -max_paths 700 -max_common_paths 1
