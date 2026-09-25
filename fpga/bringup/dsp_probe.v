// Bring-up probe: DSP multipliers against a shift-and-add reference in LUT logic.
// Random operands (LFSR). Four forms as used in rtl/: signed18 x signed18, signed18 x
// unsigned17 (x {1'b0, u}), signed9 x signed9, signed9 x unsigned8. Every product is
// recomputed serially (1 bit per clock) and compared. Prints "ss su ss9 su9\n" mismatch counts
// per second (hex) on the BL616 UART (pin 69, 115200 8N1); also unsigned18 x unsigned18 and
// unsigned9 x unsigned9 (fields 5 and 6). About 1.125 M tests per second per form.
`default_nettype none
module dsp_probe (input wire clk27, output wire uart_tx, output wire [5:0] led);
    reg [31:0] lfsr = 32'hACE1_2345;
    always @(posedge clk27) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    // operands held for one test (20 clocks)
    reg signed [17:0] a18, b18; reg [16:0] u17; reg signed [8:0] a9, b9; reg [7:0] u8;
    // DSP products, registered (as in the RTL, a register follows each multiply)
    reg signed [35:0] p_ss, p_su; reg signed [17:0] p_ss9, p_su9; reg [35:0] p_uu; reg [17:0] p_uu9;
    reg [17:0] ua18, ub18; reg [8:0] ua9, ub9;
    always @(posedge clk27) begin
        p_ss  <= a18 * b18;
        p_su  <= a18 * $signed({1'b0, u17});
        p_ss9 <= a9 * b9;
        p_su9 <= a9 * $signed({1'b0, u8});
        p_uu  <= ua18 * ub18;
        p_uu9 <= ua9 * ub9;
    end
    // serial reference: Booth-free shift-and-add on magnitudes, sign applied at the end
    function [35:0] absx(input signed [35:0] v); absx = v[35] ? -v : v; endfunction
    reg [4:0]  k = 0;
    reg [35:0] acc1, acc2, acc3, acc4, m1, m2, m3, m4, acc5, m5, acc6, m6;
    reg [17:0] q5; reg [8:0] q6;
    reg [17:0] q1, q2; reg [8:0] q3, q4;
    reg        n1, n2, n3, n4;
    reg [15:0] e1 = 0, e2 = 0, e3 = 0, e4 = 0, e5 = 0, e6 = 0, o1 = 0, o2 = 0, o3 = 0, o4 = 0, o5 = 0, o6 = 0;
    reg clr = 0;
    always @(posedge clk27) begin
        if (k == 0) begin
            a18 <= lfsr[17:0]; b18 <= lfsr[31:14]; u17 <= lfsr[16:0] ^ lfsr[31:15];
            a9 <= lfsr[8:0] ^ lfsr[20:12]; b9 <= lfsr[29:21]; u8 <= lfsr[27:20];
            ua18 <= lfsr[17:0] ^ lfsr[30:13]; ub18 <= lfsr[31:14] ^ lfsr[17:0]; ua9 <= lfsr[10:2]; ub9 <= lfsr[19:11];
        end
        if (k == 2) begin                                    // operands stable, start the reference
            m1 <= absx(a18); q1 <= absx(b18); n1 <= a18[17] ^ b18[17]; acc1 <= 0;
            m2 <= absx(a18); q2 <= {1'b0, u17}; n2 <= a18[17]; acc2 <= 0;
            m3 <= absx(a9);  q3 <= absx(b9);  n3 <= a9[8] ^ b9[8]; acc3 <= 0;
            m4 <= absx(a9);  q4 <= {1'b0, u8}; n4 <= a9[8]; acc4 <= 0;
            m5 <= {18'd0, ua18}; q5 <= ub18; acc5 <= 0; m6 <= {27'd0, ua9}; q6 <= ub9; acc6 <= 0;
        end else if (k > 2 && k <= 20) begin
            if (q1[0]) acc1 <= acc1 + m1; m1 <= m1 << 1; q1 <= q1 >> 1;
            if (q2[0]) acc2 <= acc2 + m2; m2 <= m2 << 1; q2 <= q2 >> 1;
            if (q3[0]) acc3 <= acc3 + m3; m3 <= m3 << 1; q3 <= q3 >> 1;
            if (q4[0]) acc4 <= acc4 + m4; m4 <= m4 << 1; q4 <= q4 >> 1;
            if (q5[0]) acc5 <= acc5 + m5; m5 <= m5 << 1; q5 <= q5 >> 1;
            if (q6[0]) acc6 <= acc6 + m6; m6 <= m6 << 1; q6 <= q6 >> 1;
        end
        if (k == 22) begin
            if ((n1 ? -acc1 : acc1) != p_ss)                   e1 <= e1 + 16'd1;
            if ((n2 ? -acc2 : acc2) != p_su)                   e2 <= e2 + 16'd1;
            if ((n3 ? -acc3[17:0] : acc3[17:0]) != p_ss9)      e3 <= e3 + 16'd1;
            if ((n4 ? -acc4[17:0] : acc4[17:0]) != p_su9)      e4 <= e4 + 16'd1;
            if (acc5 != p_uu)                                  e5 <= e5 + 16'd1;
            if (acc6[17:0] != p_uu9)                           e6 <= e6 + 16'd1;
        end
        if (clr) begin e1 <= 0; e2 <= 0; e3 <= 0; e4 <= 0; e5 <= 0; e6 <= 0; end
        k <= (k == 23) ? 5'd0 : k + 5'd1;
    end
    // once per second: latch and print
    reg [24:0] sec = 0; reg [5:0] ci = 0; reg go = 0; reg [7:0] dat = 0;
    reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [7:0] bt = 0;
    wire busy = (nb != 0) || go;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(posedge clk27) begin
        go <= 1'b0; sec <= sec + 25'd1;
        clr <= 1'b0;
        if (sec == 25'd26_999_999) begin sec <= 0; o1 <= e1; o2 <= e2; o3 <= e3; o4 <= e4; o5 <= e5; o6 <= e6; clr <= 1'b1; ci <= 6'd1; end
        if (ci != 0 && !busy) begin
            go <= 1'b1;
            case (ci)
                6'd1: dat <= hx(o1[15:12]); 6'd2: dat <= hx(o1[11:8]); 6'd3: dat <= hx(o1[7:4]); 6'd4: dat <= hx(o1[3:0]); 6'd5: dat <= " ";
                6'd6: dat <= hx(o2[15:12]); 6'd7: dat <= hx(o2[11:8]); 6'd8: dat <= hx(o2[7:4]); 6'd9: dat <= hx(o2[3:0]); 6'd10: dat <= " ";
                6'd11: dat <= hx(o3[15:12]); 6'd12: dat <= hx(o3[11:8]); 6'd13: dat <= hx(o3[7:4]); 6'd14: dat <= hx(o3[3:0]); 6'd15: dat <= " ";
                6'd16: dat <= hx(o4[15:12]); 6'd17: dat <= hx(o4[11:8]); 6'd18: dat <= hx(o4[7:4]); 6'd19: dat <= hx(o4[3:0]); 6'd20: dat <= " ";
                6'd21: dat <= hx(o5[15:12]); 6'd22: dat <= hx(o5[11:8]); 6'd23: dat <= hx(o5[7:4]); 6'd24: dat <= hx(o5[3:0]); 6'd25: dat <= " ";
                6'd26: dat <= hx(o6[15:12]); 6'd27: dat <= hx(o6[11:8]); 6'd28: dat <= hx(o6[7:4]); 6'd29: dat <= hx(o6[3:0]);
                default: dat <= 8'h0a;
            endcase
            ci <= (ci == 6'd30) ? 6'd0 : ci + 6'd1;
        end
        if (go) begin sh <= {1'b1, dat, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end else bt <= bt + 8'd1; end
    end
    assign uart_tx = sh[0];
    assign led = ~{2'b0, o4 != 0, o3 != 0, o2 != 0, o1 != 0};
endmodule
`default_nettype wire
