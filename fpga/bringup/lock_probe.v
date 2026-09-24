// Bring-up probe: long-term LOCK stability of the cascaded rPLLs used by rtl/clocks/clk_gen.v
// (mode 60/50: 27 x 11/2 = 148.5 -> x 5/2 = 371.25 MHz). Once per second prints
// "aa bb\r\n" (hex): number of LOCK-low events of PLL A and PLL B in that second (2-FF synced,
// 27 MHz). 115200 8N1 on the BL616 UART (pin 69).
`default_nettype none
module lock_probe (input wire clk27, output wire uart_tx, output wire [5:0] led);
    reg rst_a = 1'b1, rst_b = 1'b1; reg [15:0] rc = 0;
    wire a_clk, a_lock, b_clk, b_lock;
    rPLL #(.FCLKIN("27"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"), .IDIV_SEL(1), .FBDIV_SEL(10), .ODIV_SEL(4)) u_a (
        .CLKIN(clk27), .CLKOUT(a_clk), .LOCK(a_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(), .RESET(rst_a), .RESET_P(1'b0),
        .CLKFB(1'b0), .IDSEL(6'd62), .FBDSEL(6'd53), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    rPLL #(.FCLKIN("148.5"), .DYN_IDIV_SEL("true"), .DYN_FBDIV_SEL("true"), .IDIV_SEL(1), .FBDIV_SEL(4), .ODIV_SEL(2)) u_b (
        .CLKIN(a_clk), .CLKOUT(b_clk), .LOCK(b_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(), .RESET(rst_b), .RESET_P(1'b0),
        .CLKFB(1'b0), .IDSEL(6'd62), .FBDSEL(6'd59), .ODSEL(6'd0), .PSDA(4'd0), .DUTYDA(4'd0), .FDLY(4'd0));
    always @(posedge clk27) begin
        if (rc != 16'hFFFF) rc <= rc + 16'd1;
        if (rc == 16'd270) rst_a <= 1'b0;
        if (rc == 16'd13500) rst_b <= 1'b0;          // A has locked well before this (~150 us)
    end
    reg [2:0] la = 0, lb = 0;
    reg [7:0] na = 0, nb_ = 0, pa = 0, pb = 0;
    reg [24:0] sec = 0; reg [2:0] ci = 0;
    reg go = 0; reg [7:0] dat = 0; reg [9:0] sh = 10'h3FF; reg [3:0] nbit = 0; reg [7:0] bt = 0;
    wire busy = (nbit != 0) || go;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(posedge clk27) begin
        la <= {la[1:0], a_lock}; lb <= {lb[1:0], b_lock};
        go <= 1'b0;
        if (rc == 16'hFFFF) begin
            if (la[2] && !la[1] && na != 8'hFF) na <= na + 8'd1;
            if (lb[2] && !lb[1] && nb_ != 8'hFF) nb_ <= nb_ + 8'd1;
            sec <= sec + 25'd1;
            if (sec == 25'd26_999_999) begin sec <= 0; pa <= na; pb <= nb_; na <= 0; nb_ <= 0; ci <= 1; end
        end
        if (ci != 0 && !busy) begin
            go <= 1'b1;
            case (ci)
                3'd1: dat <= hx(pa[7:4]); 3'd2: dat <= hx(pa[3:0]); 3'd3: dat <= " ";
                3'd4: dat <= hx(pb[7:4]); 3'd5: dat <= hx(pb[3:0]); 3'd6: dat <= 8'h0d; default: dat <= 8'h0a;
            endcase
            ci <= (ci == 3'd7) ? 3'd0 : ci + 3'd1;
        end
        if (go) begin sh <= {1'b1, dat, 1'b0}; nbit <= 4'd10; bt <= 0; end
        else if (nbit != 0) begin if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nbit <= nbit - 4'd1; end else bt <= bt + 8'd1; end
    end
    assign uart_tx = sh[0];
    assign led = ~{4'b0, b_lock, a_lock};
endmodule
`default_nettype wire
