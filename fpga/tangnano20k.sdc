# Clock periods for nextpnr timing analysis (ns). nextpnr-himbaechel/gowin does not
# derive these from the rPLL/CLKDIV parameters, so they are stated here.
create_clock -period 13.468 -name pclk [get_nets pclk]
create_clock -period 18.519 -name sclk [get_nets sclk]
create_clock -period 25.000 -name lclk [get_nets lclk]
