# Clock periods for nextpnr timing analysis (ns). nextpnr-himbaechel/gowin does not
# derive these from the rPLL/CLKDIV parameters, so they are stated here.
create_clock -period 13.468 -name pclk  [get_nets pclk]
create_clock -period 25.000 -name lclk  [get_nets lclk]
create_clock -period 37.037 -name clk27 [get_nets clk27]
