// sdram_ctrl against sdram_model: write 64 bursts of a pattern, read back, compare.
`timescale 1ns/1ps
module tb_sdram;
    parameter real HALF = 6.734;       // 74.25 MHz (pixel clock); 9.259 = 54 MHz
    parameter integer CL = 3;
    parameter integer RD_LAT = 4;
    parameter RD_NEG = 0;
    reg clk = 0, rst = 1;
    always #(HALF) clk = ~clk;
    reg req = 0, req_we = 0; reg [20:0] req_addr = 0;
    wire req_ack, wd_pop, rd_valid, ready;
    wire [31:0] rdata;
    reg [31:0] wdata;
    wire sclk, cke, cs_n, ras_n, cas_n, we_n; wire [10:0] a; wire [1:0] ba; wire [3:0] dqm; wire [31:0] dq;
    sdram_ctrl #(.INIT_CYCLES(100), .CL(CL)) dut (.clk(clk), .rst(rst), .rd_lat(RD_LAT[2:0]), .rd_neg(RD_NEG[0]), .req(req), .req_we(req_we), .req_addr(req_addr),
        .req_ack(req_ack), .wdata(wdata), .wd_pop(wd_pop), .rdata(rdata), .rd_valid(rd_valid), .ready(ready),
        .sdram_clk(sclk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_addr(a), .sdram_ba(ba), .sdram_dqm(dqm), .sdram_dq(dq));
    sdram_model #(.CL(CL)) mdl (.clk(sclk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .addr(a), .ba(ba), .dqm(dqm), .dq(dq));
    function [31:0] pat(input [20:0] ad); pat = {ad[20:0], 11'h5A5} ^ (ad * 32'h9E3779B1); endfunction
    integer b, k, errs = 0, got = 0;
    reg [20:0] base;
    // write data FIFO stand-in: word k of the current burst
    reg [3:0] wi = 0;
    always @(*) wdata = pat(base + wi);
    always @(posedge clk) if (wd_pop) wi <= wi + 1;
    initial begin
        repeat (5) @(posedge clk); rst <= 0;
        wait (ready); repeat (10) @(posedge clk);
        for (b = 0; b < 64; b = b + 1) begin
            base = {b[1:0], 11'(b * 37), 8'(b * 8)} & 21'h1FFFF8;
            wi = 0; req_we <= 1; req_addr <= base; req <= 1;
            @(posedge clk); while (!req_ack) @(posedge clk); req <= 0;
            repeat (20) @(posedge clk);
        end
        for (b = 0; b < 64; b = b + 1) begin
            base = {b[1:0], 11'(b * 37), 8'(b * 8)} & 21'h1FFFF8;
            req_we <= 0; req_addr <= base; req <= 1;
            @(posedge clk); while (!req_ack) @(posedge clk); req <= 0;
            k = 0;
            while (k < 8) begin
                @(posedge clk);
                if (rd_valid) begin
                    if (rdata !== pat(base + k)) begin errs = errs + 1; if (errs < 5) $display("mismatch burst %0d word %0d: %h vs %h", b, k, rdata, pat(base + k)); end
                    k = k + 1; got = got + 1;
                end
            end
            repeat (4) @(posedge clk);
        end
        $display("tb_sdram: %0d words read, %0d mismatches, model errors %0d, refreshes %0d", got, errs, mdl.errors, mdl.refreshes);
        $finish;
    end
endmodule
