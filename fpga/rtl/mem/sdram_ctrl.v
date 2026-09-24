// Controller for the GW2AR-18 in-package SDR SDRAM: 64 Mbit, 32-bit, 4 banks x 2048
// rows x 256 columns (Sipeed nestang sdram.v header; apicula doc/sdram.md pinout).
//
// One client port, fixed 8-word bursts with auto-precharge (the frame buffer streams
// whole lines, so an open-row policy would buy little).
// Timing: CL = 2 up to ~66 MHz, CL = 3 at the 74.25 MHz pixel clock (13.5 ns);
//   tRCD: ACT->RW 3 clk; write: tWR + tRP = 5 clk after the last beat; read with auto-precharge:
//   next ACT >= 11 clk after READ; tRC >= 5 clk; AUTO REFRESH 7 clk (94 ns at 74.25 MHz)
//   refresh: one AUTO REFRESH every REFRESH_CYCLES (7.8 us; spec 4096 per 64 ms = 15.6 us)
// The SDRAM clock is the inverse of clk (ODDR at the pin): commands and write data
// launched on our rising edge are sampled by the SDRAM mid-bit.
// Read data is taken rd_lat clocks after the READ command was registered, from a rising-edge
// (rd_neg = 0) or falling-edge (rd_neg = 1, retimed) capture of DQ. The right pair depends on
// pad delays and is measured on hardware (fpga/bringup/sdram_probe.v, docs/MEASUREMENTS.md).
//
// Client write data: first-word-fall-through FIFO; wd_pop pulses in the cycle a word is used.
`default_nettype none
module sdram_ctrl #(
    parameter integer REFRESH_CYCLES = 421,      // 7.8 us at 54 MHz
    parameter integer INIT_CYCLES = 10800,       // 200 us at 54 MHz
    parameter integer CL = 2
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  rd_lat,        // clocks from READ to the first captured word
    input  wire        rd_neg,        // 1 = use the falling-edge capture
    input  wire        req,
    input  wire        req_we,
    input  wire [20:0] req_addr,      // word address: bank[20:19] row[18:8] col[7:0]; col[2:0] = 0
    output reg         req_ack,
    input  wire [31:0] wdata,
    output wire        wd_pop,
    output reg  [31:0] rdata,
    output reg         rd_valid,
    output reg         ready,
    output wire        sdram_clk,
    output reg         sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg  [10:0] sdram_addr,
    output reg  [1:0]  sdram_ba,
    output reg  [3:0]  sdram_dqm,
    inout  wire [31:0] sdram_dq
);
`ifdef SIM
    assign sdram_clk = ~clk;
`else
    ODDR u_clk_oddr (.Q0(sdram_clk), .Q1(), .D0(1'b0), .D1(1'b1), .TX(1'b0), .CLK(clk));
`endif

    reg        dq_oe;
    reg [31:0] dq_out;
    assign sdram_dq = dq_oe ? dq_out : 32'bz;
    reg [31:0] dq_in, dq_in_n, dq_n_r;
    always @(posedge clk) dq_in <= sdram_dq;
    always @(negedge clk) dq_in_n <= sdram_dq;
    always @(posedge clk) dq_n_r <= dq_in_n;
    wire [31:0] dq_cap = rd_neg ? dq_n_r : dq_in;

    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    localparam S_INIT = 4'd0, S_PRE = 4'd1, S_IREF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4,
               S_ACT = 4'd5, S_RW = 4'd6, S_WDATA = 4'd7, S_RDATA = 4'd8, S_WAIT = 4'd9;
    reg [3:0]  state;
    reg [15:0] cnt;
    reg [3:0]  n;
    reg [15:0] ref_cnt;
    reg        ref_due;
    reg        cur_we;
    reg [20:0] cur_addr;
    reg [3:0]  c;

    assign wd_pop = (state == S_RW && cur_we) || (state == S_WDATA);

    always @(posedge clk) begin
        c = C_NOP;
        req_ack <= 1'b0;
        rd_valid <= 1'b0;
        if (rst) begin
            state <= S_INIT; cnt <= 0; ready <= 1'b0; sdram_cke <= 1'b0; dq_oe <= 1'b0;
            sdram_dqm <= 4'hF; ref_cnt <= 0; ref_due <= 1'b0; n <= 0;
            sdram_addr <= 0; sdram_ba <= 0;
        end else begin
            if (ref_cnt == REFRESH_CYCLES - 1) begin ref_cnt <= 0; ref_due <= 1'b1; end
            else ref_cnt <= ref_cnt + 16'd1;
            case (state)
                S_INIT: begin
                    sdram_cke <= 1'b1;
                    if (cnt == INIT_CYCLES) begin cnt <= 0; state <= S_PRE; end
                    else cnt <= cnt + 16'd1;
                end
                S_PRE: begin
                    c = C_PRE; sdram_addr <= 11'h400;                   // all banks
                    cnt <= 16'd2; n <= 0; state <= S_IREF;
                end
                S_IREF: begin                                          // 8 x (REF, tRC)
                    if (cnt == 0) begin
                        if (n == 4'd8) state <= S_MRS;
                        else begin c = C_REF; n <= n + 4'd1; cnt <= 16'd6; end
                    end else cnt <= cnt - 16'd1;
                end
                S_MRS: begin
                    // BL 8 (A2..0 = 011), sequential (A3 = 0), CL (A6..4), burst write
                    c = C_MRS; sdram_ba <= 2'b00; sdram_addr <= {4'b0000, CL[2:0], 4'b0011};
                    sdram_dqm <= 4'h0; cnt <= 16'd3; state <= S_WAIT; ready <= 1'b1;
                end
                S_IDLE: begin
                    if (ref_due) begin
                        c = C_REF; ref_due <= 1'b0; cnt <= 16'd6; state <= S_WAIT;
                    end else if (req) begin
                        req_ack <= 1'b1;
                        cur_we <= req_we; cur_addr <= req_addr;
                        c = C_ACT; sdram_ba <= req_addr[20:19]; sdram_addr <= req_addr[18:8];
                        cnt <= 16'd1; state <= S_ACT;
                    end
                end
                S_ACT: if (cnt == 0) state <= S_RW; else cnt <= cnt - 16'd1;
                S_RW: begin
                    sdram_ba <= cur_addr[20:19];
                    sdram_addr <= {3'b100, cur_addr[7:0]};             // A10 = 1: auto-precharge
                    if (cur_we) begin
                        c = C_WR; dq_oe <= 1'b1; dq_out <= wdata; n <= 4'd1; state <= S_WDATA;
                    end else begin
                        c = C_RD; n <= 0; cnt <= {13'd0, rd_lat} - 16'd1; state <= S_RDATA;
                    end
                end
                S_WDATA: begin
                    dq_out <= wdata;
                    if (n == 4'd7) begin state <= S_WAIT; cnt <= 16'd4; end    // tWR + tRP
                    else n <= n + 4'd1;
                end
                S_RDATA: begin
                    if (cnt != 0) cnt <= cnt - 16'd1;
                    else begin
                        rdata <= dq_cap; rd_valid <= 1'b1;
                        if (n == 4'd7) begin state <= S_WAIT; cnt <= 16'd1; end
                        n <= n + 4'd1;
                    end
                end
                S_WAIT: begin
                    dq_oe <= 1'b0;
                    if (cnt == 0) state <= S_IDLE; else cnt <= cnt - 16'd1;
                end
                default: state <= S_IDLE;
            endcase
        end
        {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} <= c;
    end
endmodule
`default_nettype wire
