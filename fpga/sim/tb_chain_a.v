// Front end + video_timing on a synthetic signal: dumps line-locked composite (mV).
`timescale 1ns/1ps
module tb_chain_a;
    parameter N = 1400000;
    parameter HEX = "data/ntsc_field.hex";
    parameter OUT = "data/ntsc_field_cv.txt";
    reg clk = 0, rst = 1;
    reg [7:0] mem [0:N-1];
    reg [7:0] iq = 0; reg iq_valid = 0;
    wire signed [17:0] f20; wire f20_valid, click;
    wire signed [11:0] cv; wire cv_valid, line_start, field_odd, field_start, is_pal, locked;
    wire [10:0] cv_x; wire [9:0] line_no; wire signed [17:0] tip, blank;
    integer i, fo;
    always #12.5 clk = ~clk;
    fm_frontend #(.LUT_FILE("../rtl/dsp/phase_lut.hex")) fe (.clk(clk), .rst(rst), .iq(iq), .iq_valid(iq_valid),
        .f20(f20), .f20_valid(f20_valid), .click(click));
    video_timing vt (.clk(clk), .rst(rst), .f(f20), .f_valid(f20_valid), .cv(cv), .cv_valid(cv_valid), .cv_x(cv_x),
        .line_start(line_start), .line_no(line_no), .field_odd(field_odd), .field_start(field_start),
        .is_pal(is_pal), .locked(locked), .meas_tip(tip), .meas_blank(blank));
    initial begin
        $readmemh(HEX, mem);
        fo = $fopen(OUT, "w");
        repeat (4) @(posedge clk); rst <= 0;
        for (i = 0; i < N; i = i + 1) begin @(posedge clk); iq <= mem[i]; iq_valid <= 1; end
        $fclose(fo); fo = 0;
        $display("end: locked=%0d pal=%0d tip=%0d blank=%0d period=%0d", locked, is_pal, tip, blank, vt.period >> 16);
        $finish;
    end
    always @(posedge clk) begin
        if (cv_valid && fo != 0) $fwrite(fo, "%0d %0d %0d %0d\n", cv_x, cv, line_no, field_odd);
        if (field_start) $display("field start t=%0t odd=%0d", $time, field_odd);
    end
endmodule
