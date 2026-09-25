// Control CPU (27 MHz crystal domain, never reset by an output-rate change): PicoRV32
// (third_party/picorv32, ISC) running fpga/firmware (menu, OSD text, C5 control link).
//
// Memory map (32-bit, word accesses except the RAM, which honours byte strobes):
//   0x0000_0000  RAM, MEM_WORDS x 32, initialised from firmware/build/fw.hex
//   0x1000_0000  UART  W: tx byte          R: {.., tx_busy, rx_avail}
//   0x1000_0004  UART  R: rx byte (pops)   R bit 8: rx overflow seen
//   0x2000_0000  OSD text RAM, word index = {row[3:0], col[5:0]}, data {attr, char}
//   0x3000_0000  status   (R)  see `status` input (top.v)
//   0x3000_0004  meas_tip (R)  0x3000_0008 meas_blank (R)  0x3000_000C counters (R)
//   0x3000_0010  settings0 (RW)  0x3000_0014 settings1 (RW)  0x3000_0018 settings2 (RW)
//   0x3000_001C  osd       (RW)  0x3000_0020 millisecond counter (R)  0x3000_0024 debug (R)
//   0x3000_0028..38  link monitor: raw pins, strobe freq, edge errors p/n, bit activity (R)
//   0x3000_003C  capture: W any = start, R bit 0 = done toggle   0x4000_0000 capture buffer (R)
//   0x3000_0040  video_timing debug (R)   0x3000_0044 {broad, H sync} pulses per second (R)
//   0x3000_0048  diagnostics (R): {PLL A LOCK drops, PLL B LOCK drops, FIFO overflows, fb_ctrl state}
`default_nettype none
module soc #(
    parameter integer MEM_WORDS = 4096,
    parameter FW_HEX = "firmware/build/fw.hex"
) (
    input  wire        clk,
    input  wire        resetn,
    output wire        uart_tx,
    input  wire        uart_rx,
    output reg         osd_we,
    output reg  [9:0]  osd_waddr,
    output reg  [15:0] osd_wdata,
    input  wire [31:0] status,
    input  wire [31:0] meas_tip,
    input  wire [31:0] meas_blank,
    input  wire [31:0] counters,
    input  wire [31:0] debug,
    input  wire [31:0] link_raw,       // {16'd0, strobe edges[7:0], data pins[7:0]} (live)
    input  wire [31:0] link_freq,      // strobe edges in the last 1 s window
    input  wire [31:0] link_errp,      // rising-edge placement errors in the window
    input  wire [31:0] link_errn,      // falling-edge placement errors in the window
    input  wire [31:0] link_bits,      // {seen0[7:0], seen1[7:0]} in the window
    output reg         cap_req = 1'b0, // toggle: start a raw link capture (link_cap.v)
    input  wire        cap_done,       // toggles when the capture buffer is full (synchronised)
    output wire [10:0] cap_addr,
    input  wire [15:0] cap_data,
    input  wire [31:0] vt_dbg,         // video_timing {have_levels, locked, good[5:0], miss[7:0], 8'd0}
    input  wire [31:0] vt_pulses,      // {broad pulses, H sync pulses} in the last 1 s
    input  wire [31:0] diag,           // {PLL A drops, PLL B drops, FIFO overflows, fb_ctrl state}
    output reg  [31:0] settings0,
    output reg  [31:0] settings1,
    output reg  [31:0] settings2,
    output reg  [31:0] osd_ctrl
);
    wire        mem_valid, mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;
    picorv32 #(
        .ENABLE_COUNTERS(0), .ENABLE_COUNTERS64(0), .ENABLE_REGS_16_31(1), .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA(0), .TWO_STAGE_SHIFT(1), .BARREL_SHIFTER(0), .TWO_CYCLE_COMPARE(0),
        .TWO_CYCLE_ALU(0), .COMPRESSED_ISA(0), .CATCH_MISALIGN(0), .CATCH_ILLINSN(0),
        .ENABLE_PCPI(0), .ENABLE_MUL(0), .ENABLE_FAST_MUL(0), .ENABLE_DIV(0), .ENABLE_IRQ(0),
        .ENABLE_TRACE(0), .PROGADDR_RESET(32'h0000_0000), .STACKADDR(MEM_WORDS * 4)
    ) u_cpu (
        .clk(clk), .resetn(resetn), .trap(),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(), .mem_la_wstrb(),
        .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(), .pcpi_wr(1'b0), .pcpi_rd(32'd0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0), .irq(32'd0), .eoi(),
        .trace_valid(), .trace_data());

    // ---- RAM ----
    (* ram_style = "block" *) reg [31:0] ram [0:MEM_WORDS-1];
    initial $readmemh(FW_HEX, ram);
    wire ram_sel = mem_addr[31:28] == 4'h0;
    reg [31:0] ram_q;
    always @(posedge clk) begin
        if (mem_valid && ram_sel && !mem_ready) begin
            if (mem_wstrb[0]) ram[mem_addr[31:2]][7:0]   <= mem_wdata[7:0];
            if (mem_wstrb[1]) ram[mem_addr[31:2]][15:8]  <= mem_wdata[15:8];
            if (mem_wstrb[2]) ram[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
            if (mem_wstrb[3]) ram[mem_addr[31:2]][31:24] <= mem_wdata[31:24];
        end
        ram_q <= ram[mem_addr[31:2]];
    end

    // ---- UART ----
    wire tx_busy, rx_avail, rx_ovf; wire [7:0] rx_data;
    reg  tx_we = 0, rx_pop = 0;
    uart #(.DIV(27)) u_uart (.clk(clk), .rx(uart_rx), .tx(uart_tx), .tx_we(tx_we), .tx_data(mem_wdata[7:0]),
        .tx_busy(tx_busy), .rx_pop(rx_pop), .rx_data(rx_data), .rx_avail(rx_avail), .rx_overflow(rx_ovf));

    // ---- raw link capture read-back: 0x4000_0000 + 4 * index (registered read, 1 wait) ----
    assign cap_addr = mem_addr[12:2];
    wire [15:0] cap_q = cap_data;
    wire        cap_sel = mem_addr[31:28] == 4'h4;

    // ---- millisecond counter ----
    reg [14:0] pre = 0; reg [31:0] ms = 0;
    always @(posedge clk) if (pre == 15'd26999) begin pre <= 0; ms <= ms + 1; end else pre <= pre + 15'd1;

    // ---- bus: RAM takes two cycles (registered read), peripherals one ----
    reg ram_wait = 0;
    always @(posedge clk) begin
        mem_ready <= 1'b0; tx_we <= 1'b0; rx_pop <= 1'b0; osd_we <= 1'b0;
        if (!resetn) begin
            ram_wait <= 1'b0;
            settings0 <= 32'd0; settings1 <= {8'd0, 8'd146, 16'd0}; settings2 <= {16'd0, 8'd128, 8'd0};
            osd_ctrl <= {1'b0, 5'd0, 10'd104, 5'd0, 11'd320};
        end else if (mem_valid && !mem_ready) begin
            if (ram_sel || cap_sel) begin                 // registered-read memories: one wait cycle
                if (ram_wait) begin mem_ready <= 1'b1; mem_rdata <= ram_sel ? ram_q : {16'd0, cap_q}; ram_wait <= 1'b0; end
                else ram_wait <= 1'b1;
            end else begin
                mem_ready <= 1'b1;
                mem_rdata <= 32'd0;
                case (mem_addr[31:28])
                    4'h1: if (mem_addr[2]) begin
                              mem_rdata <= {23'd0, rx_ovf, rx_data};
                              if (mem_wstrb == 4'd0) rx_pop <= 1'b1;
                          end else begin
                              mem_rdata <= {30'd0, tx_busy, rx_avail};
                              if (mem_wstrb != 4'd0) tx_we <= 1'b1;
                          end
                    4'h2: if (mem_wstrb != 4'd0) begin
                              osd_we <= 1'b1; osd_waddr <= mem_addr[11:2]; osd_wdata <= mem_wdata[15:0];
                          end
                    4'h3: case (mem_addr[6:2])
                              5'd0: mem_rdata <= status;
                              5'd1: mem_rdata <= meas_tip;
                              5'd2: mem_rdata <= meas_blank;
                              5'd3: mem_rdata <= counters;
                              5'd4: begin mem_rdata <= settings0; if (mem_wstrb != 0) settings0 <= mem_wdata; end
                              5'd5: begin mem_rdata <= settings1; if (mem_wstrb != 0) settings1 <= mem_wdata; end
                              5'd6: begin mem_rdata <= settings2; if (mem_wstrb != 0) settings2 <= mem_wdata; end
                              5'd7: begin mem_rdata <= osd_ctrl;  if (mem_wstrb != 0) osd_ctrl  <= mem_wdata; end
                              5'd8: mem_rdata <= ms;
                              5'd9: mem_rdata <= debug;
                              5'd10: mem_rdata <= link_raw;
                              5'd11: mem_rdata <= link_freq;
                              5'd12: mem_rdata <= link_errp;
                              5'd13: mem_rdata <= link_errn;
                              5'd14: mem_rdata <= link_bits;
                              5'd15: begin mem_rdata <= {31'd0, cap_done}; if (mem_wstrb != 0) cap_req <= ~cap_req; end
                              5'd16: mem_rdata <= vt_dbg;
                              5'd17: mem_rdata <= vt_pulses;
                              5'd18: mem_rdata <= diag;
                              default: ;
                          endcase
                    default: ;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
