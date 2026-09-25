// Pipelined TMDS encoder vs the single-cycle reference (sim/ref/tmds_encoder_ref.v): random
// runs of video (all data values, long single-value runs for disparity), control, TERC4 and both
// guard bands, on all three channels; the new q must equal the reference q delayed by 3 clocks.
`timescale 1ns/1ps
module tb_tmds;
    reg clk = 0; always #5 clk = ~clk;
    reg [2:0] mode = 0; reg [7:0] data = 0; reg [1:0] ctrl = 0; reg [3:0] terc4 = 0;
    wire [9:0] q [0:2], r [0:2];
    genvar c;
    generate for (c = 0; c < 3; c = c + 1) begin : ch
        tmds_encoder     #(.CHANNEL(c)) dut (.clk(clk), .mode(mode), .data(data), .ctrl(ctrl), .terc4(terc4), .q(q[c]));
        tmds_encoder_ref #(.CHANNEL(c)) rf (.clk(clk), .mode(mode), .data(data), .ctrl(ctrl), .terc4(terc4), .q(r[c]));
    end endgenerate
    reg [9:0] rd [0:2][0:3];
    integer n = 0, e = 0, k, j, run = 0, seed = 5;
    always @(posedge clk) begin
        for (k = 0; k < 3; k = k + 1) begin
            rd[k][0] <= r[k]; rd[k][1] <= rd[k][0]; rd[k][2] <= rd[k][1];
            if (n > 8 && q[k] !== rd[k][2]) begin e = e + 1; if (e < 6) $display("ERR ch%0d t=%0d q=%b ref=%b", k, n, q[k], rd[k][2]); end
        end
        n = n + 1;
        if (run == 0) begin
            run = 1 + ($random(seed) & 255);
            j = $random(seed) & 7;
            mode <= (j < 4) ? 3'd1 : (j == 4) ? 3'd0 : (j == 5) ? 3'd2 : (j == 6) ? 3'd3 : 3'd4;
        end else run = run - 1;
        data <= (($random(seed) & 3) == 0) ? data : $random(seed);   // runs of equal values too
        ctrl <= $random(seed); terc4 <= $random(seed);
    end
    initial begin
        #2000000;
        $display("tb_tmds: %0d symbols per channel, %0d mismatches %s", n, e, e == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
