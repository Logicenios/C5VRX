// 8N1 UART, fixed divider. RX has a 2-FF synchroniser, samples mid-bit and keeps a small
// FIFO so the polled CPU can read bursts (SCAN_RESULT frames) without losing bytes.
`default_nettype none
module uart #(
    parameter integer DIV = 27               // clk / baud (27 MHz / 1 Mbaud)
) (
    input  wire       clk,
    input  wire       rx,
    output reg        tx = 1'b1,
    input  wire       tx_we,
    input  wire [7:0] tx_data,
    output wire       tx_busy,
    input  wire       rx_pop,
    output wire [7:0] rx_data,
    output wire       rx_avail,
    output reg        rx_overflow = 1'b0
);
    // ---- TX ----
    // a bit is launched when tc wraps to 0; busy lasts until the stop bit has been held
    // for a full bit period
    reg [8:0] tsh = 9'h1FF; reg [3:0] tn = 0; reg [7:0] tc = 0;
    assign tx_busy = (tn != 0) || (tc != 0);
    always @(posedge clk) begin
        if (tx_we && !tx_busy) begin tsh <= {tx_data, 1'b0}; tn <= 4'd10; tc <= 0; end
        else if (tn != 0 || tc != 0) begin
            if (tc == 0) begin tx <= tsh[0]; tsh <= {1'b1, tsh[8:1]}; tn <= tn - 4'd1; end
            tc <= (tc == DIV - 1) ? 8'd0 : tc + 8'd1;
        end
    end
    // ---- RX ----
    reg [2:0] rs = 3'b111;
    reg [3:0] rn = 0; reg [7:0] rc = 0; reg [7:0] rsh = 0;
    reg       rdone = 0;
    always @(posedge clk) begin
        rs <= {rs[1:0], rx};
        rdone <= 1'b0;
        if (rn == 0) begin
            if (!rs[2]) begin rn <= 4'd10; rc <= DIV / 2; end       // start bit edge
        end else if (rc == DIV - 1) begin
            rc <= 0;
            if (rn == 4'd10) begin if (rs[2]) rn <= 0; else rn <= rn - 4'd1; end   // false start
            else if (rn == 4'd1) begin rn <= 0; if (rs[2]) rdone <= 1'b1; end      // stop bit
            else begin rsh <= {rs[2], rsh[7:1]}; rn <= rn - 4'd1; end
        end else rc <= rc + 8'd1;
    end
    // ---- RX FIFO (512 bytes, block RAM; first-word-fall-through via a look-ahead read) ----
    (* ram_style = "block" *) reg [7:0] fifo [0:511];
    reg [9:0] wp = 0, wp_d = 0, rp = 0;
    reg [7:0] head = 0;
    wire [9:0] rp_n = rp + {9'd0, (rx_pop && rx_avail)};
    // a byte becomes visible one clock after its write, when `head` has re-read it
    assign rx_avail = (wp_d != rp);
    assign rx_data = head;
    always @(posedge clk) begin
        if (rdone) begin
            if (wp - rp == 10'd512) rx_overflow <= 1'b1;
            else begin fifo[wp[8:0]] <= rsh; wp <= wp + 10'd1; end
        end
        wp_d <= wp;
        rp <= rp_n;
        head <= fifo[rp_n[8:0]];
    end
endmodule
`default_nettype wire
