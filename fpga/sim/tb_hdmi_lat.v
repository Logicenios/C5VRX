// hdmi_tx at PIX_LATENCY L with a pixel source delayed by L: the TMDS symbol stream must not
// depend on L (checks the delay lines, e.g. PIX_LATENCY = 18 with OSD v2).
`timescale 1ns/1ps
module tb_hdmi_lat;
    parameter L = 7;
    parameter OUT = "data/hdmi_lat.txt";
    reg clk = 0; always #6.734 clk = ~clk;
    reg rst = 1;
    wire [10:0] hc; wire [9:0] vc; wire de, fs; wire [9:0] t0, t1, t2;
    reg [23:0] dl [0:31]; integer j;
    wire [23:0] src = {hc[7:0] ^ vc[7:0], hc[10:3], vc[9:2]};
    always @(posedge clk) begin dl[0] <= src; for (j = 1; j < 32; j = j + 1) dl[j] <= dl[j-1]; end
    hdmi_tx #(.PIX_LATENCY(L)) dut (.clk(clk), .rst(rst), .fmt50(1'b0), .dvi_only(1'b0), .hc(hc), .hc_next(), .vc(vc),
        .req_de(de), .frame_start(fs), .rgb(dl[L-1]), .tmds0(t0), .tmds1(t1), .tmds2(t2));
    integer fo, n = 0;
    initial begin fo = $fopen(OUT, "w"); repeat (4) @(posedge clk); rst <= 0; end
    always @(posedge clk) if (!rst) begin
        n = n + 1;
        if (n > 1650 * 750 + 200 && n <= 2 * 1650 * 750 + 200) $fwrite(fo, "%03x%03x%03x\n", t0, t1, t2);
        if (n == 2 * 1650 * 750 + 200) begin $fclose(fo); $finish; end
    end
endmodule
