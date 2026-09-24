// Port-only stubs of the Gowin primitives used by rtl/ (for `make lint`; not simulation models).
module rPLL #(parameter FCLKIN = "27", parameter DYN_IDIV_SEL = "false", parameter DYN_FBDIV_SEL = "false",
              parameter DYN_SDIV_SEL = 2, parameter IDIV_SEL = 0, parameter FBDIV_SEL = 0, parameter ODIV_SEL = 8)
    (input CLKIN, output CLKOUT, output LOCK, output CLKOUTP, output CLKOUTD, output CLKOUTD3, input RESET,
     input RESET_P, input CLKFB, input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL, input [3:0] PSDA,
     input [3:0] DUTYDA, input [3:0] FDLY);
    assign CLKOUT = CLKIN; assign LOCK = 1'b1; assign CLKOUTP = CLKIN; assign CLKOUTD = CLKIN; assign CLKOUTD3 = CLKIN;
endmodule
module CLKDIV #(parameter DIV_MODE = "2") (output CLKOUT, input HCLKIN, input RESETN, input CALIB);
    assign CLKOUT = HCLKIN;
endmodule
module OSER10 #(parameter GSREN = "false", parameter LSREN = "true")
    (output Q, input D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, input PCLK, input FCLK, input RESET);
    assign Q = D0;
endmodule
module TLVDS_OBUF (output O, output OB, input I);
    assign O = I; assign OB = ~I;
endmodule
module ODDR (output Q0, output Q1, input D0, input D1, input TX, input CLK);
    assign Q0 = D0; assign Q1 = TX;
endmodule
