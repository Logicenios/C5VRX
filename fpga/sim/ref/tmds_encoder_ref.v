// TMDS channel encoder: DVI 1.0 8b/10b video coding, control symbols, HDMI 1.4
// TERC4 data-island symbols and guard bands.
//
// mode: 0 = control (ctrl[1:0]), 1 = video (data), 2 = data island (terc4),
//       3 = video guard band, 4 = data-island guard band
// channel: 0/1/2 selects the per-channel guard-band pattern (HDMI 1.4 §5.2.2.1/§5.2.3.3).
`default_nettype none
module tmds_encoder_ref #(
    parameter [1:0] CHANNEL = 0
) (
    input  wire       clk,
    input  wire [2:0] mode,
    input  wire [7:0] data,
    input  wire [1:0] ctrl,
    input  wire [3:0] terc4,
    output reg  [9:0] q
);
    // ---- 8b/10b video coding (DVI 1.0 §3.3.1) ----
    function [3:0] ones8(input [7:0] d);
        ones8 = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    endfunction

    wire [3:0] n1d = ones8(data);
    wire use_xnor = (n1d > 4) || (n1d == 4 && data[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = data[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : g_qm
            assign qm[i] = use_xnor ? ~(qm[i-1] ^ data[i]) : (qm[i-1] ^ data[i]);
        end
    endgenerate
    assign qm[8] = ~use_xnor;

    wire [3:0] n1q = ones8(qm[7:0]);
    wire [3:0] n0q = 4'd8 - n1q;
    reg signed [4:0] disparity = 5'sd0;

    // ---- TERC4 (HDMI 1.4 Table 5-17) ----
    reg [9:0] terc;
    always @(*) begin
        case (terc4)
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

    // ---- control symbols (DVI 1.0 Table 3-2) ----
    reg [9:0] ctl;
    always @(*) begin
        case (ctrl)
            2'b00: ctl = 10'b1101010100;
            2'b01: ctl = 10'b0010101011;
            2'b10: ctl = 10'b0101010100;
            default: ctl = 10'b1010101011;
        endcase
    end

    // ---- guard bands (HDMI 1.4 §5.2.2.1 video, §5.2.3.3 data island) ----
    wire [9:0] video_gb = (CHANNEL == 1) ? 10'b0100110011 : 10'b1011001100;
    wire [9:0] island_gb = (CHANNEL == 0) ? terc : 10'b0100110011;

    always @(posedge clk) begin
        case (mode)
            3'd1: begin
                if (disparity == 0 || n1q == n0q) begin
                    q <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
                    disparity <= qm[8] ? disparity + $signed({1'b0, n1q}) - $signed({1'b0, n0q})
                                       : disparity + $signed({1'b0, n0q}) - $signed({1'b0, n1q});
                end else if ((disparity > 0 && n1q > n0q) || (disparity < 0 && n0q > n1q)) begin
                    q <= {1'b1, qm[8], ~qm[7:0]};
                    disparity <= disparity + $signed({3'b0, qm[8], 1'b0}) + $signed({1'b0, n0q}) - $signed({1'b0, n1q});
                end else begin
                    q <= {1'b0, qm[8], qm[7:0]};
                    disparity <= disparity - $signed({3'b0, ~qm[8], 1'b0}) + $signed({1'b0, n1q}) - $signed({1'b0, n0q});
                end
            end
            3'd2: begin q <= terc;      disparity <= 5'sd0; end
            3'd3: begin q <= video_gb;  disparity <= 5'sd0; end
            3'd4: begin q <= island_gb; disparity <= 5'sd0; end
            default: begin q <= ctl;    disparity <= 5'sd0; end
        endcase
    end
endmodule
`default_nettype wire
