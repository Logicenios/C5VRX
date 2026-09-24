// Bring-up probe: embedded SDRAM at the 74.25 MHz pixel clock. For CAS latency CL
// (parameter; one bitstream each), rd_lat 2..6 and rising/falling capture: reset the controller, write 2048 bursts
// (16,384 words) spread over all banks and rows with a seed-dependent pattern, read
// them back and count wrong words. SOAK = 1 repeats rd_lat 4 on both edges forever. Prints "c l n eeeeeeee\r\n" (hex) on the BL616 UART.
`default_nettype none
module sdram_probe #(parameter integer CL = 3, parameter integer SOAK = 0) (
    input  wire        clk27,
    output wire        uart_tx,
    output wire [5:0]  led,
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    wire clk, lock;
    pll_74 u_pll (.clock_in(clk27), .clock_out(clk), .locked(lock));

    reg [2:0] lat = (SOAK != 0) ? 3'd4 : 3'd2;
    reg       neg = 0;
    reg       crst = 1;
    wire req_ack, wd_pop, rd_valid, ready;
    reg  req = 0, req_we = 0; reg [20:0] req_addr = 0;
    wire [31:0] rdata;
    reg  [7:0] seed = 8'h5A;
    function [31:0] pat(input [20:0] a, input [7:0] sd);
        pat = ({a, 11'h2A5} ^ ({a, 11'd0} >> 7) ^ (a * 32'h9E3779B1)) + {4{sd}};
    endfunction
    reg [11:0] b = 0;                  // burst index
    wire [20:0] base = {b * 12'd1021, 9'd0} ^ {b[1:0], 19'd0};   // spread over rows and banks
    reg  [2:0] wi = 0, ri = 0;
    reg  [20:0] cur = 0;
    wire [31:0] wdata = pat(cur + wi, seed);
    wire cl3 = (CL == 3);

    sdram_ctrl #(.REFRESH_CYCLES(579), .INIT_CYCLES(14850), .CL(CL)) u_sd (
        .clk(clk), .rst(crst), .rd_lat(lat), .rd_neg(neg),
        .req(req), .req_we(req_we), .req_addr(req_addr), .req_ack(req_ack), .wdata(wdata), .wd_pop(wd_pop),
        .rdata(rdata), .rd_valid(rd_valid), .ready(ready),
        .sdram_clk(O_sdram_clk), .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
        .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n), .sdram_addr(O_sdram_addr), .sdram_ba(O_sdram_ba),
        .sdram_dqm(O_sdram_dqm), .sdram_dq(IO_sdram_dq));

    localparam [2:0] S_RST = 0, S_INIT = 1, S_WR = 2, S_RD = 3, S_DRAIN = 4, S_PRINT = 5, S_NEXT = 6, S_DONE = 7;
    reg [2:0]  st = S_RST;
    reg [15:0] t = 0;
    reg [31:0] errs = 0;
    reg        infl = 0;
    reg [4:0]  ci = 0;
    reg        tx_go = 0; reg [7:0] tx_data = 0; wire tx_busy;
    reg [7:0]  tx_ch;
    function [7:0] hx(input [3:0] v); hx = (v < 10) ? 8'h30 + v : 8'h57 + v; endfunction
    always @(*) case (ci)
        0: tx_ch = cl3 ? 8'h33 : 8'h32; 1: tx_ch = 8'h20; 2: tx_ch = hx({1'b0, lat}); 3: tx_ch = 8'h20;
        4: tx_ch = neg ? 8'h31 : 8'h30; 5: tx_ch = 8'h20;
        6: tx_ch = hx(errs[31:28]); 7: tx_ch = hx(errs[27:24]); 8: tx_ch = hx(errs[23:20]); 9: tx_ch = hx(errs[19:16]);
        10: tx_ch = hx(errs[15:12]); 11: tx_ch = hx(errs[11:8]); 12: tx_ch = hx(errs[7:4]); 13: tx_ch = hx(errs[3:0]);
        14: tx_ch = 8'h0d; default: tx_ch = 8'h0a;
    endcase
    always @(posedge clk) begin
        tx_go <= 1'b0;
        case (st)
            S_RST:  begin crst <= 1'b1; t <= t + 16'd1; if (t == 16'd100) begin crst <= 1'b0; t <= 0; st <= S_INIT; end end
            S_INIT: if (ready) begin b <= 0; errs <= 0; infl <= 0; st <= S_WR; end
            S_WR: begin
                if (!req && !infl) begin req <= 1'b1; req_we <= 1'b1; req_addr <= base; cur <= base; wi <= 0; end
                if (req && req_ack) begin req <= 1'b0; infl <= 1'b1; end
                if (infl && wd_pop) begin
                    wi <= wi + 3'd1;
                    if (wi == 3'd7) begin infl <= 1'b0; if (b == 12'd2047) begin b <= 0; st <= S_RD; end else b <= b + 12'd1; end
                end
            end
            S_RD: begin
                if (!req && !infl) begin req <= 1'b1; req_we <= 1'b0; req_addr <= base; cur <= base; ri <= 0; end
                if (req && req_ack) begin req <= 1'b0; infl <= 1'b1; end
                if (infl && rd_valid) begin
                    if (rdata != pat(cur + ri, seed)) errs <= errs + 32'd1;
                    ri <= ri + 3'd1;
                    if (ri == 3'd7) begin infl <= 1'b0; if (b == 12'd2047) begin ci <= 0; st <= S_PRINT; end else b <= b + 12'd1; end
                end
                if (infl && !rd_valid) begin t <= t + 16'd1; if (t == 16'd2000) begin errs <= 32'hFFFFFFFF; infl <= 1'b0; ci <= 0; st <= S_PRINT; end end
                else t <= 0;
            end
            S_PRINT: if (!tx_busy && !tx_go) begin
                tx_data <= tx_ch; tx_go <= 1'b1;
                if (ci == 5'd15) st <= S_NEXT; else ci <= ci + 5'd1;
            end
            S_NEXT: begin
                seed <= seed + 8'd37; t <= 0; st <= S_RST;
                if (SOAK != 0) begin lat <= 3'd4; neg <= ~neg; end      // soak: CL2 lat 4, both edges, forever
                else if (neg) begin
                    neg <= 1'b0;
                    if (lat == 3'd6) begin lat <= 3'd2; st <= S_DONE; end
                    else lat <= lat + 3'd1;
                end else neg <= 1'b1;
            end
            default: ;
        endcase
    end

    // UART 115200 8N1 from 74.25 MHz: 644.5 -> 644
    reg [9:0] sh = 10'h3FF; reg [3:0] nb = 0; reg [9:0] bt = 0;
    assign tx_busy = (nb != 0) || tx_go;
    assign uart_tx = sh[0];
    always @(posedge clk) begin
        if (tx_go) begin sh <= {1'b1, tx_data, 1'b0}; nb <= 4'd10; bt <= 0; end
        else if (nb != 0) begin
            if (bt == 10'd643) begin bt <= 0; sh <= {1'b1, sh[9:1]}; nb <= nb - 4'd1; end
            else bt <= bt + 10'd1;
        end
    end
    assign led = ~{st == S_DONE, cl3, neg, lat};
endmodule
`default_nettype wire
