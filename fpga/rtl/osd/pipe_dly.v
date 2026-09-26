// N-clock delay line of individual flip-flops. Gowin otherwise maps register chains into LUT-RAM
// shift registers, whose read delay set the OSD's critical path (MEASUREMENTS M81).
`default_nettype none
module pipe_dly #(
    parameter integer W = 1,
    parameter integer N = 1
) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
) /* synthesis syn_srlstyle = "registers" */;
    genvar i;
    generate for (i = 0; i < N; i = i + 1) begin : st
        reg [W-1:0] r;
        if (i == 0) begin : first
            always @(posedge clk) r <= d;
        end else begin : next
            always @(posedge clk) r <= st[i - 1].r;
        end
    end endgenerate
    assign q = st[N - 1].r;
endmodule
`default_nettype wire
