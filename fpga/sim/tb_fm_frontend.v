// Bit-exact check of rtl/dsp/fm_frontend.v against model/ref.py fm_frontend().
`timescale 1ns/1ps
module tb_fm_frontend;
    parameter N = 84000;
    parameter HEX = "data/ntsc_bars.hex";
    parameter OUT = "data/ntsc_bars_fe_rtl.txt";
    reg clk = 0, rst = 1;
    reg [7:0] mem [0:N-1];
    reg [7:0] iq = 0;
    reg iq_valid = 0;
    wire signed [17:0] f20;
    wire f20_valid, click;
    integer i, fo, nout;
    always #12.5 clk = ~clk;
    fm_frontend #(.LUT_FILE("../rtl/dsp/phase_lut.hex")) dut (
        .clk(clk), .rst(rst), .iq(iq), .iq_valid(iq_valid), .f20(f20), .f20_valid(f20_valid), .click(click));
    initial begin
        $readmemh(HEX, mem);
        fo = $fopen(OUT, "w");
        nout = 0;
        repeat (4) @(posedge clk);
        rst <= 0;
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            iq <= mem[i];
            iq_valid <= 1;
        end
        @(posedge clk); iq_valid <= 0;
        repeat (20) @(posedge clk);
        $fclose(fo);
        $display("tb_fm_frontend: %0d outputs", nout);
        $finish;
    end
    always @(posedge clk) if (f20_valid) begin $fwrite(fo, "%0d\n", f20); nout = nout + 1; end
endmodule
