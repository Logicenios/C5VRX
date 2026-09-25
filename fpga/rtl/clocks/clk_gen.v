// HDMI/system clocks from the 27 MHz crystal with run-time rate selection (fpga/README.md §5.4a).
//
// Two cascaded rPLLs, both with dynamic dividers (encoding measured: IDIV = 64 - IDSEL,
// FBDIV = 64 - FBDSEL; docs/MEASUREMENTS.md M58):
//   mode 60 / 50 : 27 x 11/2 = 148.5   -> x 5/2   = 371.25 MHz   (VCO 594 / 742.5 MHz)
//   mode 59.94   : 27 x 50/7 = 192.857 -> x 25/13 = 370.879 MHz  (VCO 771 / 741.8 MHz)
// Measured 371.2499 / 370.8790 MHz, relock ~0.3 ms (M59). fclk drives the OSER10s and
// pclk = fclk / 5 everything else (SDRAM included), so a mode change resets the whole
// pixel domain; `locked` is low from the request until PLL B relocks.
`default_nettype none
module clk_gen (
    input  wire       clk27,
    input  wire [1:0] mode,        // clk27 domain: 0 = 720p60, 1 = 720p59.94, 2 = 720p50
    output wire       fclk,        // 5 x pixel clock
    output wire       pclk,        // 74.25 / 74.176 MHz
    output reg        locked = 1'b0,
    output reg  [1:0] mode_cur = 2'd0,
    output reg  [7:0] restarts = 8'd0,    // times the pixel domain was restarted after first lock
    output reg  [1:0] last_cause = 2'd0,  // 1 = PLL A lock lost, 2 = PLL B lock lost, 3 = mode change
    output reg  [7:0] drops_a = 8'd0,     // diagnostics: LOCK A / B falling edges while running,
    output reg  [7:0] drops_b = 8'd0      //   of any length (saturating)
);
    reg  rst_a = 1'b1, rst_b = 1'b1;
    reg  sel5994 = 1'b0;
    wire a_clk, a_lock, b_lock;
    rPLL #(.FCLKIN("27"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"),
           .IDIV_SEL(1), .FBDIV_SEL(10), .ODIV_SEL(4)) u_a (
        .CLKIN(clk27), .CLKOUT(a_clk), .LOCK(a_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(rst_a), .RESET_P(1'b0), .CLKFB(1'b0),
        .IDSEL(sel5994 ? 6'd57 : 6'd62), .FBDSEL(sel5994 ? 6'd14 : 6'd53), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    rPLL #(.FCLKIN("148.5"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"),
           .IDIV_SEL(1), .FBDIV_SEL(4), .ODIV_SEL(2)) u_b (
        .CLKIN(a_clk), .CLKOUT(fclk), .LOCK(b_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(rst_b), .RESET_P(1'b0), .CLKFB(1'b0),
        .IDSEL(sel5994 ? 6'd51 : 6'd62), .FBDSEL(sel5994 ? 6'd39 : 6'd59), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    CLKDIV #(.DIV_MODE("5")) u_div (.CLKOUT(pclk), .HCLKIN(fclk), .RESETN(locked), .CALIB(1'b0));

    wire [1:0] mode_m = (mode == 2'd3) ? 2'd0 : mode;
    reg [1:0] la_s = 0, lb_s = 0;
    always @(posedge clk27) begin la_s <= {la_s[0], a_lock}; lb_s <= {lb_s[0], b_lock}; end

    // LOCK is debounced: PLL B's LOCK can chatter for a few hundred microseconds after a retune
    // (MEASUREMENTS M63), and restarting on every glitch re-triggers the retune and blanks HDMI
    // again. The output is released only after both LOCKs have been high for 2 ms, and a
    // running output is restarted only after a LOCK has been low for 1 ms.
    localparam [1:0] S_RST = 0, S_LA = 1, S_LB = 2, S_RUN = 3;
    reg [1:0]  st = S_RST;
    reg [17:0] t = 0;                     // 27 MHz cycles; lock timeout 5 ms -> restart
    reg [15:0] good = 0, bad = 0;         // debounce counters
    always @(posedge clk27) begin
        t <= t + 18'd1;
        case (st)
            S_RST: begin
                rst_a <= 1'b1; rst_b <= 1'b1; locked <= 1'b0; good <= 0; bad <= 0;
                sel5994 <= (mode_cur == 2'd1);
                if (t == 18'd270) begin rst_a <= 1'b0; t <= 0; st <= S_LA; end     // 10 us in reset
            end
            S_LA: if (la_s[1]) begin rst_b <= 1'b0; t <= 0; st <= S_LB; end
                  else if (t == 18'd135000) begin t <= 0; st <= S_RST; end
            S_LB: begin
                good <= (la_s[1] && lb_s[1]) ? good + 16'd1 : 16'd0;
                if (good == 16'd54000) begin t <= 0; bad <= 0; st <= S_RUN; end          // 2 ms stable
                else if (t == 18'd216000) begin t <= 0; st <= S_RST; end                  // 8 ms: retry
            end
            S_RUN: begin
                locked <= 1'b1;
                if (la_s == 2'b10 && drops_a != 8'hFF) drops_a <= drops_a + 8'd1;
                if (lb_s == 2'b10 && drops_b != 8'hFF) drops_b <= drops_b + 8'd1;
                bad <= (la_s[1] && lb_s[1]) ? 16'd0 : bad + 16'd1;
                if (bad == 16'd27000 || mode_m != mode_cur) begin                       // 1 ms low
                    last_cause <= (mode_m != mode_cur) ? 2'd3 : !la_s[1] ? 2'd1 : 2'd2;
                    mode_cur <= mode_m; locked <= 1'b0; t <= 0; st <= S_RST;
                    if (restarts != 8'hFF) restarts <= restarts + 8'd1;
                end
            end
        endcase
    end
endmodule
`default_nettype wire
