// Bring-up probe: input register test. Prints "a b" (0/1) at ~10 Hz on the BL616
// USB-UART for two otherwise floating pins, one pulled up and one pulled down (iob_probe.cst).
`default_nettype none
module iob_probe (input wire clk27, input wire btn_s1, input wire btn_s2, output wire uart_tx, output wire [5:0] led);
    reg [1:0] a = 0, b = 0;
    always @(posedge clk27) begin a <= {a[0], btn_s1}; b <= {b[0], btn_s2}; end
    reg [21:0] t = 0; reg [2:0] ci = 0; reg go = 0; reg [7:0] dat = 0;
    reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [7:0] bt = 0;
    wire busy = (nb != 0) || go;
    always @(posedge clk27) begin
        go <= 1'b0; t <= t + 22'd1;
        if (t == 22'd2_700_000) begin t <= 0; ci <= 1; end
        if (ci != 0 && !busy) begin
            go <= 1'b1;
            case (ci)
                3'd1: dat <= a[1] ? "1" : "0"; 3'd2: dat <= " "; 3'd3: dat <= b[1] ? "1" : "0";
                3'd4: dat <= 8'h0d; default: dat <= 8'h0a;
            endcase
            ci <= (ci == 3'd5) ? 3'd0 : ci + 3'd1;
        end
        if (go) begin sh <= {1'b1, dat, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin if (bt == 8'd233) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end else bt <= bt + 8'd1; end
    end
    assign uart_tx = sh[0];
    assign led = ~{4'b0, b[1], a[1]};
endmodule
`default_nettype wire
