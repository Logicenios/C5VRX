// Bring-up probe: block RAM width modes. The fm_frontend phase table (256 x 25) is read from a
// block RAM in the 36-bit mode (one 25-bit wide memory) and from a 16-bit + a 9-bit block RAM,
// and each read is compared with the same table held in LUT logic. Prints the mismatch counts
// per second, "wide split\n" (hex), on the BL616 UART (pin 69, 115200 8N1).
`default_nettype none
module bram_probe (input wire clk27, output wire uart_tx, output wire [5:0] led);
    (* ram_style = "block" *) reg [24:0] wide [0:255];
    (* ram_style = "block" *) reg [15:0] ph   [0:255];
    (* ram_style = "block" *) reg [8:0]  r2   [0:255];
    initial $readmemh("../rtl/dsp/phase_lut.hex", wide);
    initial $readmemh("../rtl/dsp/phase_ph.hex", ph);
    initial $readmemh("../rtl/dsp/phase_r2.hex", r2);
    // expected values as logic (a case ROM built from the same file by yosys: distributed)
    (* ram_style = "logic" *) reg [24:0] ref_rom [0:255];
    initial $readmemh("../rtl/dsp/phase_lut.hex", ref_rom);
    reg [7:0] a = 0; reg [24:0] qw, qref; reg [15:0] qp; reg [8:0] qr;
    always @(posedge clk27) begin
        a <= a + 8'd1;
        qw <= wide[a]; qp <= ph[a]; qr <= r2[a]; qref <= ref_rom[a];
    end
    reg [15:0] e36 = 0, esp = 0, p36 = 0, psp = 0; reg [24:0] sec = 0; reg [1:0] warm = 0;
    reg [3:0] ci = 0; reg go = 0; reg [7:0] dat = 0; reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [7:0] bt = 0;
    wire busy = (nb != 0) || go;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(posedge clk27) begin
        go <= 1'b0;
        if (warm != 2'd3) warm <= warm + 2'd1;
        else begin
            if (qw != qref && e36 != 16'hFFFF) e36 <= e36 + 16'd1;
            if ({qr, qp} != qref && esp != 16'hFFFF) esp <= esp + 16'd1;
        end
        sec <= sec + 25'd1;
        if (sec == 25'd26_999_999) begin sec <= 0; p36 <= e36; psp <= esp; e36 <= 0; esp <= 0; ci <= 4'd1; end
        if (ci != 0 && !busy) begin
            go <= 1'b1;
            case (ci)
                4'd1: dat <= hx(p36[15:12]); 4'd2: dat <= hx(p36[11:8]); 4'd3: dat <= hx(p36[7:4]); 4'd4: dat <= hx(p36[3:0]);
                4'd5: dat <= " ";
                4'd6: dat <= hx(psp[15:12]); 4'd7: dat <= hx(psp[11:8]); 4'd8: dat <= hx(psp[7:4]); 4'd9: dat <= hx(psp[3:0]);
                default: dat <= 8'h0a;
            endcase
            ci <= (ci == 4'd10) ? 4'd0 : ci + 4'd1;
        end
        if (go) begin sh <= {1'b1, dat, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end else bt <= bt + 8'd1; end
    end
    assign uart_tx = sh[0];
    assign led = ~{4'b0, psp != 0, p36 != 0};
endmodule
`default_nettype wire
