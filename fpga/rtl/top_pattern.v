// Bring-up top: 720p HDMI colour bars with a moving bar, to prove the
// open-source toolchain, the TMDS path and the AVI InfoFrame on the Tang Nano 20K.
//   S1 (pin 88): toggle 720p60 / 720p50        S2 (pin 87): toggle HDMI / DVI
//   LED0 on = PLL locked, LED1 on = 50 Hz, LED2 on = DVI mode, LED5 blinks = pixel clock alive
`default_nettype none
module top_pattern (
    input  wire       clk27,
    input  wire       btn_s1,
    input  wire       btn_s2,
    output wire [5:0] led,          // active low on the Tang Nano 20K
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire fclk, lock, pclk;
    pll_tmds_60 u_pll (.clock_in(clk27), .clock_out(fclk), .locked(lock));
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(pclk), .HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0));

    reg [3:0] rst_cnt = 4'hF;
    always @(posedge pclk or negedge lock)
        if (!lock) rst_cnt <= 4'hF; else if (rst_cnt != 0) rst_cnt <= rst_cnt - 4'd1;
    wire rst = rst_cnt != 0;

    // ---- buttons: 2-FF sync + ~10 ms debounce, toggle on press ----
    reg [1:0] s1_sync, s2_sync;
    reg [19:0] db_cnt;
    reg s1_state, s2_state, fmt50, dvi_only;
    always @(posedge pclk) begin
        s1_sync <= {s1_sync[0], btn_s1};
        s2_sync <= {s2_sync[0], btn_s2};
        db_cnt <= db_cnt + 20'd1;
        if (rst) begin
            s1_state <= 1'b0; s2_state <= 1'b0; fmt50 <= 1'b0; dvi_only <= 1'b0;
        end else if (db_cnt == 0) begin
            s1_state <= s1_sync[1];
            s2_state <= s2_sync[1];
            if (s1_sync[1] && !s1_state) fmt50 <= ~fmt50;
            if (s2_sync[1] && !s2_state) dvi_only <= ~dvi_only;
        end
    end

    wire [10:0] hc; wire [9:0] vc; wire de, fs;
    reg [23:0] rgb_q, rgb_q2;
    reg [10:0] bar_x;
    always @(posedge pclk) begin
        if (fs) bar_x <= (bar_x >= 11'd1279) ? 11'd0 : bar_x + 11'd4;
        // 75% colour bars (8 x 160 px), white moving bar
        case (hc[10:7] >> 0)
            4'd0, 4'd1: rgb_q <= 24'hBFBFBF;
            4'd2, 4'd3: rgb_q <= 24'hBFBF00;
            4'd4:       rgb_q <= 24'h00BFBF;
            4'd5:       rgb_q <= 24'h00BF00;
            4'd6:       rgb_q <= 24'hBF00BF;
            4'd7:       rgb_q <= 24'hBF0000;
            4'd8:       rgb_q <= 24'h0000BF;
            default:    rgb_q <= 24'h000000;
        endcase
        if (hc >= bar_x && hc < bar_x + 11'd16) rgb_q <= 24'hFFFFFF;
        if (vc < 10'd8 || vc >= 10'd712) rgb_q <= 24'hFF8000;  // top/bottom markers
        rgb_q2 <= rgb_q;
    end

    wire [9:0] t0, t1, t2;
    hdmi_tx #(.PIX_LATENCY(2)) u_tx (
        .clk(pclk), .rst(rst), .fmt50(fmt50), .dvi_only(dvi_only), .afd_4x3(1'b0),
        .hc(hc), .vc(vc), .req_de(de), .frame_start(fs), .rgb(rgb_q2),
        .tmds0(t0), .tmds1(t1), .tmds2(t2));
    hdmi_phy u_phy (.pclk(pclk), .fclk(fclk), .rst(rst), .d0(t0), .d1(t1), .d2(t2),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n));

    reg [25:0] blink;
    always @(posedge pclk) blink <= blink + 26'd1;
    assign led = ~{blink[25], 2'b00, dvi_only, fmt50, lock};
endmodule
`default_nettype wire
