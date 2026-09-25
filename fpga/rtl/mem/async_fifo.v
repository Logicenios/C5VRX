// Dual-clock FIFO: gray-coded pointers with 2-FF synchronisers (Cummings, SNUG 2002),
// first-word-fall-through read side (rd_data is the head whenever !empty).
`default_nettype none
module async_fifo #(
    parameter integer WIDTH = 36,
    parameter integer AW = 9                     // depth 2^AW
) (
    input  wire             wclk, wrst,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,
    output wire [AW:0]      wr_level,            // approximate (synchronised read pointer)
    input  wire             rclk, rrst,
    input  wire             rd_en,               // pop the head
    output reg  [WIDTH-1:0] rd_data,
    output wire             empty,
    output reg  [AW:0]      rd_level             // words available after this clock's pop (registered;
                                                 // never more than are there: writes only add)
);
    reg [WIDTH-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
    reg [AW:0] rgray_w1 = 0, rgray_w2 = 0, wgray_r1 = 0, wgray_r2 = 0;

    function [AW:0] g2b(input [AW:0] g);
        integer i;
        begin
            g2b[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction

    // ---- write side ----
    wire [AW:0] wbin_n = wbin + {{AW{1'b0}}, (wr_en && !full)};
    wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
    assign full = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
    assign wr_level = wbin - g2b(rgray_w2);
    always @(posedge wclk) begin
        if (wrst) begin wbin <= 0; wgray <= 0; end
        else begin
            if (wr_en && !full) mem[wbin[AW-1:0]] <= wr_data;
            wbin <= wbin_n; wgray <= wgray_n;
        end
        rgray_w1 <= rgray; rgray_w2 <= rgray_w1;
    end

    // ---- read side (FWFT: read address looks ahead on pop) ----
    wire [AW:0] rbin_n = rbin + {{AW{1'b0}}, (rd_en && !empty)};
    wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;
    assign empty = (rgray == wgray_r2);
    // registered (the Gray decode and subtract fed the reader's decision logic combinationally and
    // failed timing at 74.25 MHz; MEASUREMENTS M75)
    always @(posedge rclk) begin
        if (rrst) begin rbin <= 0; rgray <= 0; rd_level <= 0; end
        else begin rbin <= rbin_n; rgray <= rgray_n; rd_level <= g2b(wgray_r2) - rbin_n; end
        rd_data <= mem[rbin_n[AW-1:0]];
        wgray_r1 <= wgray; wgray_r2 <= wgray_r1;
    end
endmodule
`default_nettype wire
