// osd2.v against model/osd2_ref.py (bit-exact): random registers, text and a known video
// pattern; after a commit the next frame's 1280 x 720 output is compared with the model.
`timescale 1ns/1ps
module tb_osd2;
    parameter REGS = "data/osd2_regs.hex";
    parameter TEXT = "data/osd2_text.hex";
    parameter OUT  = "data/osd2_rtl.txt";
    reg pclk = 0, wclk = 0;
    always #6.734 pclk = ~pclk;
    always #18.519 wclk = ~wclk;
    reg [31:0] regs [0:31]; reg [15:0] text [0:1023];
    reg we = 0, rwe = 0; reg [9:0] waddr = 0; reg [15:0] wdata = 0; reg [4:0] raddr = 0; reg [31:0] rdata = 0;
    reg [10:0] hc = 0; reg [9:0] vc = 0;
    always @(posedge pclk) begin
        if (hc == 11'd1649) begin hc <= 0; vc <= (vc == 10'd749) ? 10'd0 : vc + 10'd1; end
        else hc <= hc + 11'd1;
    end
    // video pattern, valid 6 clocks after (hc, vc)
    reg [10:0] hd [0:19]; reg [9:0] vd [0:19];
    integer i, j;   // separate loop variables: j in the clocked delay line, i in the initial block
    always @(posedge pclk) begin
        hd[0] <= hc; vd[0] <= vc;
        for (j = 1; j <= 19; j = j + 1) begin hd[j] <= hd[j-1]; vd[j] <= vd[j-1]; end
    end
    // hd[k] = hc k+1 clocks ago: rgb_in at time t for (hc, vc) of t-6 -> hd[5]
    wire [10:0] h6 = hd[5]; wire [9:0] v6 = vd[5];
    wire [7:0] pr = h6 * 5 + v6 * 3, pg = h6 ^ {v6, 1'b0}, pb = (h6 + v6 * 7) >> 2;
    wire [23:0] rgb_in = {pr, pg, pb};
    wire [23:0] rgb_out; wire creq, cack;
    wire [10:0] hc_nx = (hc == 11'd1649) ? 11'd0 : hc + 11'd1;
    wire [9:0]  vc_nx = (hc != 11'd1649) ? vc : (vc == 10'd749) ? 10'd0 : vc + 10'd1;
    osd2 #(.FONT_FILE("../rtl/osd/font.hex")) dut (.clk(pclk), .hc_nx(hc_nx), .vc_nx(vc_nx), .wclk(wclk), .we(we), .waddr(waddr), .wdata(wdata),
        .rwe(rwe), .raddr(raddr), .rdata(rdata), .commit_req(creq), .commit_ack(cack), .rgb_in(rgb_in), .rgb_out(rgb_out));
    // rgb_out at time t belongs to (hc, vc) of t-18 -> hd[17]
    wire [10:0] h10 = hd[17]; wire [9:0] v10 = vd[17];
    integer fo, n = 0; reg cap = 0, armed = 0; reg ack0;
    initial begin
        $readmemh(REGS, regs); $readmemh(TEXT, text);
        fo = $fopen(OUT, "w");
        repeat (4) @(posedge wclk);
        for (i = 0; i < 1024; i = i + 1) begin @(posedge wclk); we <= 1; waddr <= i; wdata <= text[i]; end
        @(posedge wclk); we <= 0;
        for (i = 0; i <= 29; i = i + 1) begin @(posedge wclk); rwe <= 1; raddr <= i; rdata <= regs[i]; end
        @(posedge wclk); raddr <= 5'd31;
        @(posedge wclk); rwe <= 0;
        ack0 = cack;
        wait (cack != ack0);
        armed = 1;
    end
    always @(posedge pclk) begin
        if (armed && !cap && hc == 11'd0 && vc == 10'd0) cap <= 1;
        if (cap && h10 < 11'd1280 && v10 < 10'd720) begin
            $fwrite(fo, "%06x\n", rgb_out); n = n + 1;
            if (n == 1280 * 720) begin $fclose(fo); $display("tb_osd2: %0d pixels", n); $finish; end
        end
    end
endmodule
