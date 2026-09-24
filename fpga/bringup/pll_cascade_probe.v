// Bring-up probe: cascaded rPLLs retuned at run time (fpga/README.md §5.4a).
//   mode 0: 27 x 11/2 = 148.5 -> x 5/2 = 371.25 MHz      (720p60 / 720p50 TMDS)
//   mode 1: 27 x 50/7 = 192.857 -> x 25/13 = 370.879 MHz (720p59.94 TMDS)
// Dynamic encoding measured with pll_probe.v: IDIV = 64 - IDSEL, FBDIV = 64 - FBDSEL.
// Each switch: hold both PLLs in reset, release A, wait LOCK A, release B, wait LOCK B,
// then count B's CLKOUTD (/8) for 100 ms of the 27 MHz crystal.
// Prints "m ttttttt uuuuuuu nnnnnnnn\r\n" (hex: mode, A lock time, B lock time in 27 MHz
// cycles, count) at 115200 8N1 on the BL616 UART (pin 69).
`default_nettype none
module pll_cascade_probe (
    input  wire       clk27,
    output wire       uart_tx,
    output wire [5:0] led
);
    reg mode = 1'b0, rst_a = 1'b1, rst_b = 1'b1;
    wire a_clk, a_lock, b_clk, b_div, b_lock;
    rPLL #(.FCLKIN("27"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"),
           .IDIV_SEL(1), .FBDIV_SEL(10), .ODIV_SEL(4)) u_a (
        .CLKIN(clk27), .CLKOUT(a_clk), .LOCK(a_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(rst_a), .RESET_P(1'b0), .CLKFB(1'b0),
        .IDSEL(mode ? 6'd57 : 6'd62), .FBDSEL(mode ? 6'd14 : 6'd53), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    rPLL #(.FCLKIN("148.5"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"), .DYN_SDIV_SEL(8),
           .IDIV_SEL(1), .FBDIV_SEL(4), .ODIV_SEL(2)) u_b (
        .CLKIN(a_clk), .CLKOUT(b_clk), .LOCK(b_lock), .CLKOUTP(), .CLKOUTD(b_div), .CLKOUTD3(),
        .RESET(rst_b), .RESET_P(1'b0), .CLKFB(1'b0),
        .IDSEL(mode ? 6'd51 : 6'd62), .FBDSEL(mode ? 6'd39 : 6'd59), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));

    reg gate = 0, epoch = 0;
    reg [2:0] g_s = 0; reg [1:0] e_s = 0;
    reg [31:0] cnt = 0; reg cnt_epoch = 0;
    always @(posedge b_div) begin
        g_s <= {g_s[1:0], gate}; e_s <= {e_s[0], epoch};
        if (g_s[1] && !g_s[2]) begin cnt <= 0; cnt_epoch <= e_s[1]; end
        else if (g_s[1]) cnt <= cnt + 32'd1;
    end
    reg [1:0] ce_s = 0, la_s = 0, lb_s = 0;
    always @(posedge clk27) begin ce_s <= {ce_s[0], cnt_epoch}; la_s <= {la_s[0], a_lock}; lb_s <= {lb_s[0], b_lock}; end

    localparam [2:0] S_RST = 0, S_LA = 1, S_LB = 2, S_SETTLE = 3, S_GATE = 4, S_READ = 5, S_PRINT = 6;
    reg [2:0]  st = S_RST;
    reg [27:0] t = 0, ta = 0, tb = 0;
    reg [31:0] res;
    reg [4:0]  ci = 0;
    reg        tx_go = 0; reg [7:0] tx_data = 0; wire tx_busy;
    reg [7:0]  tx_ch;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(*) case (ci)
        0: tx_ch = mode ? 8'h31 : 8'h30; 1: tx_ch = 8'h20;
        2: tx_ch = hx(ta[27:24]); 3: tx_ch = hx(ta[23:20]); 4: tx_ch = hx(ta[19:16]); 5: tx_ch = hx(ta[15:12]);
        6: tx_ch = hx(ta[11:8]); 7: tx_ch = hx(ta[7:4]); 8: tx_ch = hx(ta[3:0]); 9: tx_ch = 8'h20;
        10: tx_ch = hx(tb[27:24]); 11: tx_ch = hx(tb[23:20]); 12: tx_ch = hx(tb[19:16]); 13: tx_ch = hx(tb[15:12]);
        14: tx_ch = hx(tb[11:8]); 15: tx_ch = hx(tb[7:4]); 16: tx_ch = hx(tb[3:0]); 17: tx_ch = 8'h20;
        18: tx_ch = hx(res[31:28]); 19: tx_ch = hx(res[27:24]); 20: tx_ch = hx(res[23:20]); 21: tx_ch = hx(res[19:16]);
        22: tx_ch = hx(res[15:12]); 23: tx_ch = hx(res[11:8]); 24: tx_ch = hx(res[7:4]); 25: tx_ch = hx(res[3:0]);
        26: tx_ch = 8'h0d; default: tx_ch = 8'h0a;
    endcase
    always @(posedge clk27) begin
        tx_go <= 1'b0;
        t <= t + 28'd1;
        case (st)
            S_RST:    begin rst_a <= 1'b1; rst_b <= 1'b1;
                          if (t == 28'd270) begin rst_a <= 1'b0; t <= 0; st <= S_LA; end end
            S_LA:     if (la_s[1]) begin ta <= t; rst_b <= 1'b0; t <= 0; st <= S_LB; end
                      else if (t == 28'd27000000) begin ta <= 28'hFFFFFFF; t <= 0; st <= S_READ; end
            S_LB:     if (lb_s[1]) begin tb <= t; t <= 0; st <= S_SETTLE; end
                      else if (t == 28'd27000000) begin tb <= 28'hFFFFFFF; t <= 0; st <= S_READ; end
            S_SETTLE: if (t == 28'd27000) begin epoch <= ~epoch; gate <= 1'b1; t <= 0; st <= S_GATE; end
            S_GATE:   if (t == 28'd2700000 - 1) begin gate <= 1'b0; t <= 0; st <= S_READ; end
            S_READ:   if (t == 28'd100) begin res <= (ce_s[1] == epoch) ? cnt : 32'hFFFFFFFF; ci <= 0; st <= S_PRINT; end
            S_PRINT:  if (!tx_busy && !tx_go) begin
                          tx_data <= tx_ch; tx_go <= 1'b1;
                          if (ci == 5'd27) begin mode <= ~mode; t <= 0; st <= S_RST; end
                          else ci <= ci + 5'd1;
                      end
            default:  st <= S_RST;
        endcase
    end

    reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [7:0] bt = 0;
    assign tx_busy = (nb != 0) || tx_go;
    assign uart_tx = sh[0];
    always @(posedge clk27) begin
        if (tx_go) begin sh <= {1'b1, tx_data, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin
            if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end
            else bt <= bt + 8'd1;
        end
    end
    assign led = ~{mode, a_lock, b_lock, 3'b000};
endmodule
`default_nettype wire
