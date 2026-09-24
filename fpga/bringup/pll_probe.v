// Bring-up probe: measures the rPLL output for every dynamic IDSEL/FBDSEL code so the
// port encoding (not documented in the sources used here) is established by measurement.
// For each (IDSEL, FBDSEL): pulse RESET, wait 2 ms, then count CLKOUT for 10 ms of the
// 27 MHz crystal. Prints "ii ff l nnnnnnnn\r\n" (hex; l = LOCK) at 115200 8N1 on the
// BL616 USB-UART (pin 69). ODIV is static 8 so CLKOUT = VCO / 8 stays countable.
`default_nettype none
module pll_probe (
    input  wire       clk27,
    output wire       uart_tx,
    output wire [5:0] led
);
    reg [5:0] ids = 0, fbs = 0;
    reg       prst = 1'b1;
    wire      pclk, lock;
    rPLL #(.FCLKIN("27"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"),
           .IDIV_SEL(0), .FBDIV_SEL(3), .ODIV_SEL(8)) u_pll (
        .CLKIN(clk27), .CLKOUT(pclk), .LOCK(lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(prst), .RESET_P(1'b0), .CLKFB(1'b0), .FBDSEL(fbs), .IDSEL(ids), .ODSEL(6'd0),
        .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));

    // ---- counter in the PLL domain, gated from the reference domain ----
    reg gate = 0, epoch = 0;
    reg [2:0] g_s = 0; reg [1:0] e_s = 0;
    reg [31:0] cnt = 0; reg cnt_epoch = 0;
    always @(posedge pclk) begin
        g_s <= {g_s[1:0], gate}; e_s <= {e_s[0], epoch};
        if (g_s[1] && !g_s[2]) begin cnt <= 0; cnt_epoch <= e_s[1]; end
        else if (g_s[1]) cnt <= cnt + 32'd1;
    end
    reg [1:0] ce_s = 0; always @(posedge clk27) ce_s <= {ce_s[0], cnt_epoch};

    // ---- sequencer (27 MHz) ----
    localparam [2:0] S_RST = 0, S_WAIT = 1, S_GATE = 2, S_SETTLE = 3, S_PRINT = 4, S_NEXT = 5, S_DONE = 6;
    reg [2:0]  st = S_RST;
    reg [23:0] t = 0;
    reg        lk;
    reg [31:0] res;
    reg [4:0]  ci;                                     // character index 0..17
    reg        tx_go = 0; wire tx_busy;
    reg [7:0]  tx_ch;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(*) case (ci)
        0: tx_ch = hx({2'b0, ids[5:4]}); 1: tx_ch = hx(ids[3:0]); 2: tx_ch = 8'h20;
        3: tx_ch = hx({2'b0, fbs[5:4]}); 4: tx_ch = hx(fbs[3:0]); 5: tx_ch = 8'h20;
        6: tx_ch = lk ? 8'h31 : 8'h30; 7: tx_ch = 8'h20;
        8: tx_ch = hx(res[31:28]); 9: tx_ch = hx(res[27:24]); 10: tx_ch = hx(res[23:20]); 11: tx_ch = hx(res[19:16]);
        12: tx_ch = hx(res[15:12]); 13: tx_ch = hx(res[11:8]); 14: tx_ch = hx(res[7:4]); 15: tx_ch = hx(res[3:0]);
        16: tx_ch = 8'h0d; default: tx_ch = 8'h0a;
    endcase
    always @(posedge clk27) begin
        tx_go <= 1'b0;
        case (st)
            S_RST:    begin prst <= 1'b1; t <= t + 1; if (t == 24'd270) begin prst <= 1'b0; t <= 0; st <= S_WAIT; end end
            S_WAIT:   begin t <= t + 1; if (t == 24'd54000) begin t <= 0; lk <= lock; epoch <= ~epoch; gate <= 1'b1; st <= S_GATE; end end
            S_GATE:   begin t <= t + 1; if (t == 24'd270000 - 1) begin gate <= 1'b0; t <= 0; st <= S_SETTLE; end end
            S_SETTLE: begin t <= t + 1; if (t == 24'd100) begin
                          res <= (ce_s[1] == epoch) ? cnt : 32'hFFFFFFFF;   // no clock -> FFFFFFFF
                          lk <= lk & lock; ci <= 0; t <= 0; st <= S_PRINT; end end
            S_PRINT:  if (!tx_busy && !tx_go) begin
                          tx_go <= 1'b1;
                          if (ci == 5'd17) st <= S_NEXT; else ci <= ci + 5'd1;
                      end
            S_NEXT:   if (!tx_busy && !tx_go) begin
                          fbs <= fbs + 6'd1; if (fbs == 6'd63) ids <= ids + 6'd1;
                          st <= (fbs == 6'd63 && ids == 6'd63) ? S_DONE : S_RST;
                      end
            default:  ;
        endcase
    end

    // ---- UART TX 115200 8N1 (27e6 / 115200 = 234.4 -> 234, +0.2 %) ----
    reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [7:0] bt = 0;
    assign tx_busy = (nb != 0);
    assign uart_tx = sh[0];
    always @(posedge clk27) begin
        if (tx_go) begin sh <= {1'b1, tx_ch, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin
            if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end
            else bt <= bt + 8'd1;
        end
    end
    assign led = ~{st == S_DONE, lock, ids[3:0]};
endmodule
`default_nettype wire
