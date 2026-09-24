// C5 -> FPGA sample-link monitor (docs/FPGA_LINK.md §2.3, lab item L3.3).
//
// Runs on the link STROBE (lclk). Per 1 s window (window toggles from the crystal domain):
//   samples : STROBE rising edges in the window -> strobe frequency (40,000,000 expected)
//   seen0/1 : each data bit was seen low / high (stuck or open wires)
//   err_p/n : edge-placement statistic. Data are captured on the rising (p) and the falling (n)
//             STROBE edge, 12.5 ns apart: two consecutive native ~80 MS/s modem samples when the
//             edges sit inside the data eye. The FM I/Q moves little between neighbouring native
//             samples, so a capture on a data transition (a mix of old and new bits) stands out
//             against the midpoint of its two neighbours:
//               err_n counts dn[k] with max(|2 dn[k] - dp[k] - dp[k+1]|) >= ERR_T (I or Q)
//               err_p counts dp[k] with max(|2 dp[k] - dn[k-1] - dn[k]|) >= ERR_T
//             The two edges are one native sample period apart, so both sit at the same point
//             of the eye and the counts rise together (a lasting p/n difference means the STROBE
//             duty cycle is not 50 %). Low counts: clean captures, 80 MS/s capture is safe.
//             High counts: the edges sit on the transitions (sim/tb_link_mon.v: 0 mid-eye,
//             ~16 % within +-0.5 ns of a transition). Counts that cycle over minutes: STROBE and
//             the modem bus drift (issue #12). Needs a real signal (VTX on); with noise only,
//             the counts are high everywhere.
// edges   : free-running count of STROBE rising edges (the wiring test counts single edges).
// Nibbles are two's complement, byte = {I[3:0], Q[3:0]} (THEORY §2).
`default_nettype none
module link_mon #(
    parameter integer ERR_T = 6              // |2x - a - b| threshold, nibble LSB units
) (
    input  wire        lclk,
    input  wire [7:0]  link_d,               // raw pins (falling-edge capture)
    input  wire [7:0]  dp_in,                // rising-edge capture (top.v iq_cap)
    input  wire        win_tog,              // toggles once per window (crystal domain)
    output reg  [25:0] samples = 0,          // results of the last completed window
    output reg  [25:0] err_p = 0,
    output reg  [25:0] err_n = 0,
    output reg  [7:0]  seen0 = 0,
    output reg  [7:0]  seen1 = 0,
    output reg  [7:0]  edges = 0
);
    reg [7:0] dn_raw = 0;
    always @(negedge lclk) dn_raw <= link_d;

    // after rising edge k: p1 = dp[k-1], m1 = dn[k-1], p2 = dp[k-2], m2 = dn[k-2]
    reg [7:0] p1 = 0, p2 = 0, m1 = 0, m2 = 0;
    function signed [6:0] dev(input [3:0] x, input [3:0] a, input [3:0] b);   // |2x - a - b|
        reg signed [6:0] d;
        begin
            d = {{2{x[3]}}, x, 1'b0} - {{3{a[3]}}, a} - {{3{b[3]}}, b};
            dev = (d < 0) ? -d : d;
        end
    endfunction
    wire bad_n = (dev(m2[7:4], p2[7:4], p1[7:4]) >= ERR_T) || (dev(m2[3:0], p2[3:0], p1[3:0]) >= ERR_T);
    wire bad_p = (dev(p1[7:4], m2[7:4], m1[7:4]) >= ERR_T) || (dev(p1[3:0], m2[3:0], m1[3:0]) >= ERR_T);

    reg [2:0]  ws = 0;
    reg [25:0] c_s = 0, c_p = 0, c_n = 0;
    reg [7:0]  c_0 = 0, c_1 = 0;
    wire       win_end = ws[2] ^ ws[1];
    always @(posedge lclk) begin
        edges <= edges + 8'd1;
        p1 <= dp_in; p2 <= p1; m1 <= dn_raw; m2 <= m1;
        ws <= {ws[1:0], win_tog};
        if (win_end) begin
            samples <= c_s; err_p <= c_p; err_n <= c_n; seen0 <= c_0; seen1 <= c_1;
            c_s <= 26'd1; c_p <= 26'd0; c_n <= 26'd0; c_0 <= 8'd0; c_1 <= 8'd0;   // this edge counts
        end else begin
            if (c_s != {26{1'b1}}) c_s <= c_s + 26'd1;
            if (bad_p && c_p != {26{1'b1}}) c_p <= c_p + 26'd1;
            if (bad_n && c_n != {26{1'b1}}) c_n <= c_n + 26'd1;
            c_0 <= c_0 | ~dp_in | ~dn_raw;
            c_1 <= c_1 | dp_in | dn_raw;
        end
    end
endmodule
`default_nettype wire
