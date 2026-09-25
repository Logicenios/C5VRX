// OSD with the registered window position vs the previous OSD (sim/ref/osd_ref.v): a 1650 x 750
// raster, random text-RAM writes and window moves, random video; rgb_out must be identical.
`timescale 1ns/1ps
module tb_osd;
    reg clk = 0, wclk = 0; always #5 clk = ~clk; always #13 wclk = ~wclk;
    reg [10:0] hc = 0; reg [9:0] vc = 0; reg enable = 1; reg [10:0] x0 = 320; reg [9:0] y0 = 104;
    reg we = 0; reg [9:0] waddr = 0; reg [15:0] wdata = 0; reg [23:0] rgb_in = 0;
    wire [23:0] a, b;
    osd     dut (.clk(clk), .hc(hc), .vc(vc), .enable(enable), .x0(x0), .y0(y0), .wclk(wclk), .we(we),
                 .waddr(waddr), .wdata(wdata), .rgb_in(rgb_in), .rgb_out(a));
    osd_ref rf  (.clk(clk), .hc(hc), .vc(vc), .enable(enable), .x0(x0), .y0(y0), .wclk(wclk), .we(we),
                 .waddr(waddr), .wdata(wdata), .rgb_in(rgb_in), .rgb_out(b));
    integer n = 0, e = 0, fgn = 0, seed = 11;
    always @(posedge wclk) begin we <= ($random(seed) & 1) && (vc >= 730); // writes in vertical blanking: no read/write race
        waddr <= $random(seed); wdata <= $random(seed); end
    always @(posedge clk) begin
        if (hc == 1649) begin hc <= 0; vc <= (vc == 749) ? 0 : vc + 1;
            // the window (512 lines from y0 <= 127) ends before the write lines (vc >= 730)
            if (vc == 749) begin x0 <= $random(seed) & 1023; y0 <= $random(seed) & 127; enable <= ($random(seed) & 3) != 0; end
        end else hc <= hc + 1;
        rgb_in <= $random(seed);
        n = n + 1;
        if (n > 16) begin
            if (a !== b) begin e = e + 1; if (e < 4) $display("ERR t=%0d hc=%0d vc=%0d new=%h ref=%h | x0=%0d y0=%0d en=%0d | ref: in1=%0d at2=%h fq=%h | new: in1=%0d at2=%h fq=%h | we=%0d waddr=%0d", n, hc, vc, a, b, x0, y0, enable, rf.in1, rf.at2, rf.fq, dut.in1, dut.at2, dut.fq, we, waddr); end
            if (a !== rgb_in) fgn = fgn + 1;
        end
    end
    initial begin
        #(10 * 1650 * 750 * 3);
        $display("tb_osd: %0d pixels, %0d overlaid, %0d mismatches %s", n, fgn, e, e == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
