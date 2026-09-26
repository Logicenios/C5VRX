// TMDS physical layer for GW2A: one OSER10 (10:1 DDR serializer) per lane into a
// true-LVDS output buffer. fclk = 5 x pclk (DDR -> 10 bits per pixel clock).
// Clock lane sends 10'b0000011111 (pixel-rate square wave). Bit 0 is sent first.
`default_nettype none
module hdmi_phy (
    input  wire       pclk,      // pixel clock (74.25 / 74.176 MHz)
    input  wire       fclk,      // 5 x pixel clock
    input  wire       rst,
    input  wire [9:0] d0, d1, d2,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    // one register stage right before the serialisers, so the last hop into the IO logic is short
    // wherever the encoder is placed
    reg [9:0] d0_r, d1_r, d2_r;
    always @(posedge pclk) begin d0_r <= d0; d1_r <= d1; d2_r <= d2; end
    wire [9:0] lane [0:3];
    assign lane[0] = d0_r;
    assign lane[1] = d1_r;
    assign lane[2] = d2_r;
    assign lane[3] = 10'b0000011111;
    wire [3:0] ser;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            OSER10 ser10 (
                .Q(ser[i]),
                .D0(lane[i][0]), .D1(lane[i][1]), .D2(lane[i][2]), .D3(lane[i][3]), .D4(lane[i][4]),
                .D5(lane[i][5]), .D6(lane[i][6]), .D7(lane[i][7]), .D8(lane[i][8]), .D9(lane[i][9]),
                .PCLK(pclk), .FCLK(fclk), .RESET(rst)
            );
        end
    endgenerate

    TLVDS_OBUF obuf_clk (.I(ser[3]), .O(tmds_clk_p), .OB(tmds_clk_n));
    TLVDS_OBUF obuf_d0  (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    TLVDS_OBUF obuf_d1  (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    TLVDS_OBUF obuf_d2  (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
endmodule
`default_nettype wire
