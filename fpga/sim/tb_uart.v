// UART loopback: TX -> RX at 1 Mbaud from 27 MHz, 300 bytes, checks order and data.
`timescale 1ns/1ps
module tb_uart;
    reg clk = 0; always #18.518 clk = ~clk;
    wire line; reg we = 0; reg [7:0] d = 0; wire busy, avail; wire [7:0] q; reg pop = 0; wire ovf;
    uart #(.DIV(27)) u (.clk(clk), .rx(line), .tx(line), .tx_we(we), .tx_data(d), .tx_busy(busy),
                        .rx_pop(pop), .rx_data(q), .rx_avail(avail), .rx_overflow(ovf));
    integer sent = 0, got = 0, errs = 0;
    always @(posedge clk) begin
        we <= 1'b0; pop <= 1'b0;
        if (!busy && !we && sent < 300) begin we <= 1'b1; d <= sent[7:0] ^ 8'h5A; sent <= sent + 1; end
        if (avail && !pop) begin
            if (q != (got[7:0] ^ 8'h5A)) errs = errs + 1;
            got = got + 1; pop <= 1'b1;
        end
    end
    initial begin #4_000_000; $display("tb_uart: sent %0d got %0d errors %0d ovf %0d %s", sent, got, errs, ovf,
                                        (got == 300 && errs == 0) ? "PASS" : "FAIL"); $finish; end
endmodule
