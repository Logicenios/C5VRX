// clk_gen lock debouncing: an rPLL model whose LOCK rises 150 us after RESET is released and
// then chatters (20 us low every 100 us) for 600 us, as seen on the board after a retune
// (MEASUREMENTS M63). Expect: one clean start, exactly one restart per mode change, no
// restarts caused by the chatter, and `locked` never toggling while the mode is constant.
`timescale 1ns/1ps
module rPLL #(parameter FCLKIN = "27", parameter DYN_IDIV_SEL = "false", parameter DYN_FBDIV_SEL = "false",
              parameter IDIV_SEL = 0, parameter FBDIV_SEL = 0, parameter ODIV_SEL = 8)
    (input CLKIN, output CLKOUT, output reg LOCK = 0, output CLKOUTP, output CLKOUTD, output CLKOUTD3,
     input RESET, input RESET_P, input CLKFB, input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL,
     input [3:0] PSDA, input [3:0] DUTYDA, input [3:0] FDLY);
    assign CLKOUT = CLKIN; assign CLKOUTP = CLKIN; assign CLKOUTD = CLKIN; assign CLKOUTD3 = CLKIN;
    time t_rel = 0; reg was_rst = 1;
    always @(posedge CLKIN) begin
        if (RESET) begin LOCK <= 1'b0; was_rst <= 1'b1; end
        else begin
            if (was_rst) begin t_rel = $time; was_rst <= 1'b0; end
            if ($time - t_rel < 150_000) LOCK <= 1'b0;
            else if ($time - t_rel < 750_000) LOCK <= (($time - t_rel) % 100_000) >= 20_000;
            else LOCK <= 1'b1;
        end
    end
endmodule
module CLKDIV #(parameter DIV_MODE = "5") (output CLKOUT, input HCLKIN, input RESETN, input CALIB);
    assign CLKOUT = HCLKIN;
endmodule
module tb_clkgen;
    reg clk = 0; always #18.518 clk = ~clk;
    reg [1:0] mode = 0;
    wire fclk, pclk, locked; wire [1:0] mode_cur; wire [7:0] restarts; wire [1:0] cause;
    clk_gen dut (.clk27(clk), .mode(mode), .fclk(fclk), .pclk(pclk), .locked(locked), .mode_cur(mode_cur),
                 .restarts(restarts), .last_cause(cause));
    integer rises = 0, errs = 0; reg ld = 0;
    always @(posedge clk) begin ld <= locked; if (locked && !ld) rises = rises + 1; end
    initial begin
        #10_000_000;                                   // 10 ms: start-up with chatter
        if (rises != 1 || restarts != 0) begin errs = errs + 1; $display("ERR start: rises %0d restarts %0d", rises, restarts); end
        mode = 1; #10_000_000;                         // retune to 59.94 (chatter again)
        if (rises != 2 || restarts != 1 || cause != 3 || mode_cur != 1) begin errs = errs + 1; $display("ERR 59.94: rises %0d restarts %0d cause %0d", rises, restarts, cause); end
        mode = 2; #10_000_000;
        if (rises != 3 || restarts != 2 || mode_cur != 2) begin errs = errs + 1; $display("ERR 50: rises %0d restarts %0d", rises, restarts); end
        $display("tb_clkgen: output starts %0d, restarts %0d, last cause %0d, errors %0d %s", rises, restarts, cause, errs,
                 errs == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
