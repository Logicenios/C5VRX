// Quasi-static bus crossing: two synchroniser stages, and the output only takes a value that
// was seen twice in a row, so a multi-bit value is never torn. For settings and slowly
// changing status (the source must hold each value for >= 3 destination clocks).
`default_nettype none
module cdc_bus #(parameter integer W = 8) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output reg  [W-1:0] q = {W{1'b0}}
);
    reg [W-1:0] s1 = {W{1'b0}}, s2 = {W{1'b0}};
    always @(posedge clk) begin
        s1 <= d; s2 <= s1;
        if (s1 == s2) q <= s2;
    end
endmodule
`default_nettype wire
