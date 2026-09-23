`timescale 1ns/1ps
module tb_chroma_pal;
    parameter N = 256000;
    parameter IN = "data/chroma_in.txt";
    parameter OUT = "data/chroma_rtl.txt";
    parameter COMB = 1;
    reg clk = 0, rst = 1;
    reg signed [11:0] cv = 0; reg cv_valid = 0; reg [10:0] cv_x = 0;
    wire signed [11:0] y; wire signed [15:0] u, v; wire [10:0] xo; wire ov, killed, sw;
    integer fi, fo, i, xx, val, r;
    always #12.5 clk = ~clk;
    chroma_dec #(.SIN_FILE("../rtl/dsp/sin_lut.hex"), .COS_FILE("../rtl/dsp/cos_lut.hex")) dut (
        .clk(clk), .rst(rst), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x), .is_pal(1'b1), .comb(COMB[0]),
        .hue(16'd0), .sat(8'd146), .y_out(y), .u_out(u), .v_out(v), .x_out(xo), .out_valid(ov),
        .killed(killed), .pal_sw_neg(sw));
    initial begin
        fi = $fopen(IN, "r"); fo = $fopen(OUT, "w");
        repeat (4) @(posedge clk); rst <= 0;
        for (i = 0; i < N; i = i + 1) begin
            r = $fscanf(fi, "%d %d\n", xx, val);
            @(posedge clk); cv <= val; cv_x <= xx; cv_valid <= 1;
            @(posedge clk); cv_valid <= 0;
        end
        repeat (20) @(posedge clk);
        $fclose(fo); $finish;
    end
    always @(posedge clk) if (ov) $fwrite(fo, "%0d %0d %0d %0d\n", xo, y, u, v);
endmodule
