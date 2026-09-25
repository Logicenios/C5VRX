// TMDS channel encoder: DVI 1.0 8b/10b video coding, control symbols, HDMI 1.4
// TERC4 data-island symbols and guard bands.
//
// mode: 0 = control (ctrl[1:0]), 1 = video (data), 2 = data island (terc4),
//       3 = video guard band, 4 = data-island guard band
// channel: 0/1/2 selects the per-channel guard-band pattern (HDMI 1.4 §5.2.2.1/§5.2.3.3).
//
// Pipelined: q is valid LATENCY = 4 clocks after (mode, data, ctrl, terc4). The single-cycle
// version failed timing by 2.6 ns at 74.25 MHz in Gowin's analysis (MEASUREMENTS M75); a TMDS
// encoder that misses timing emits wrong symbols (sparkles) and loses its running disparity
// (receivers drop the link). Stages: 0 input register; 1 q_m (XOR/XNOR chain); 2 popcount of
// q_m and the fixed symbols; 3 disparity and output select (the only recurrence, a 5-bit add).
// All channels have the same latency, so the stream is only delayed; sim/tb_tmds.v checks it
// symbol for symbol against the single-cycle encoder (sim/ref/tmds_encoder_ref.v).
`default_nettype none
module tmds_encoder #(
    parameter [1:0] CHANNEL = 0
) (
    input  wire       clk,
    input  wire [2:0] mode,
    input  wire [7:0] data,
    input  wire [1:0] ctrl,
    input  wire [3:0] terc4,
    output reg  [9:0] q
);
    localparam integer LATENCY = 4;
    function [3:0] ones8(input [7:0] d);
        ones8 = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    endfunction

    // ---- stage 0: input register ----
    reg [2:0] m0; reg [7:0] d0; reg [1:0] c0; reg [3:0] t0;
    always @(posedge clk) begin m0 <= mode; d0 <= data; c0 <= ctrl; t0 <= terc4; end

    // ---- stage 1: 8b/10b transition minimisation (DVI 1.0 §3.3.1) ----
    wire [3:0] n1d = ones8(d0);
    wire use_xnor = (n1d > 4) || (n1d == 4 && d0[0] == 1'b0);
    wire [8:0] qm_w;
    assign qm_w[0] = d0[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : g_qm
            assign qm_w[i] = use_xnor ? ~(qm_w[i-1] ^ d0[i]) : (qm_w[i-1] ^ d0[i]);
        end
    endgenerate
    assign qm_w[8] = ~use_xnor;
    reg [8:0] qm1; reg [2:0] m1; reg [1:0] c1; reg [3:0] t1;
    always @(posedge clk) begin qm1 <= qm_w; m1 <= m0; c1 <= c0; t1 <= t0; end

    // ---- stage 2: popcount of q_m; the fixed symbols ----
    // TERC4 (HDMI 1.4 Table 5-17)
    reg [9:0] terc;
    always @(*) begin
        case (t1)
            4'b0000: terc = 10'b1010011100;
            4'b0001: terc = 10'b1001100011;
            4'b0010: terc = 10'b1011100100;
            4'b0011: terc = 10'b1011100010;
            4'b0100: terc = 10'b0101110001;
            4'b0101: terc = 10'b0100011110;
            4'b0110: terc = 10'b0110001110;
            4'b0111: terc = 10'b0100111100;
            4'b1000: terc = 10'b1011001100;
            4'b1001: terc = 10'b0100111001;
            4'b1010: terc = 10'b0110011100;
            4'b1011: terc = 10'b1011000110;
            4'b1100: terc = 10'b1010001110;
            4'b1101: terc = 10'b1001110001;
            4'b1110: terc = 10'b0101100011;
            default: terc = 10'b1011000011;
        endcase
    end
    // control symbols (DVI 1.0 Table 3-2)
    reg [9:0] ctl;
    always @(*) begin
        case (c1)
            2'b00: ctl = 10'b1101010100;
            2'b01: ctl = 10'b0010101011;
            2'b10: ctl = 10'b0101010100;
            default: ctl = 10'b1010101011;
        endcase
    end
    // guard bands (HDMI 1.4 §5.2.2.1 video, §5.2.3.3 data island)
    wire [9:0] video_gb = (CHANNEL == 1) ? 10'b0100110011 : 10'b1011001100;
    wire [9:0] island_gb = (CHANNEL == 0) ? terc : 10'b0100110011;
    reg [8:0] qm2; reg [3:0] n1q2; reg vid2; reg [9:0] sym2;
    always @(posedge clk) begin
        qm2 <= qm1; n1q2 <= ones8(qm1[7:0]); vid2 <= (m1 == 3'd1);
        case (m1)
            3'd2:    sym2 <= terc;
            3'd3:    sym2 <= video_gb;
            3'd4:    sym2 <= island_gb;
            default: sym2 <= ctl;
        endcase
    end

    // ---- stage 3: running disparity and output ----
    wire [3:0] n0q2 = 4'd8 - n1q2;
    reg signed [4:0] disparity = 5'sd0;
    always @(posedge clk) begin
        if (vid2) begin
            if (disparity == 0 || n1q2 == n0q2) begin
                q <= {~qm2[8], qm2[8], qm2[8] ? qm2[7:0] : ~qm2[7:0]};
                disparity <= qm2[8] ? disparity + $signed({1'b0, n1q2}) - $signed({1'b0, n0q2})
                                    : disparity + $signed({1'b0, n0q2}) - $signed({1'b0, n1q2});
            end else if ((disparity > 0 && n1q2 > n0q2) || (disparity < 0 && n0q2 > n1q2)) begin
                q <= {1'b1, qm2[8], ~qm2[7:0]};
                disparity <= disparity + $signed({3'b0, qm2[8], 1'b0}) + $signed({1'b0, n0q2}) - $signed({1'b0, n1q2});
            end else begin
                q <= {1'b0, qm2[8], qm2[7:0]};
                disparity <= disparity - $signed({3'b0, ~qm2[8], 1'b0}) + $signed({1'b0, n1q2}) - $signed({1'b0, n0q2});
            end
        end else begin
            q <= sym2; disparity <= 5'sd0;
        end
    end
endmodule
`default_nettype wire
