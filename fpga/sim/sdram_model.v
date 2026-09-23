// Behavioural SDR SDRAM model for the GW2AR-18 in-package part (64 Mbit, x32,
// 4 banks x 2048 rows x 256 columns). Supports MRS (checks BL 8 / CL 2), ACT,
// READ/WRITE with auto-precharge (burst 8, sequential), PRE (all), AUTO REFRESH.
// Output timing: data for CL = 2 appears tAC after the (k+1)-th clock edge and is
// held tOH after the next edge (typical -6/-7 speed grade: tAC 5.4 ns, tOH 2.5 ns).
// Protocol violations are counted and reported.
`timescale 1ns/1ps
module sdram_model #(
    parameter real T_AC = 5.4,
    parameter real T_OH = 2.5
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n, ras_n, cas_n, we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:(1<<21)-1];
    reg [10:0] open_row [0:3];
    reg        row_open [0:3];
    reg        mode_ok = 0;
    integer    errors = 0, reads = 0, writes = 0, refreshes = 0;
    integer    i;
    initial for (i = 0; i < 4; i = i + 1) row_open[i] = 0;

    reg [31:0] dq_drv;
    reg        dq_en = 0;
    assign dq = dq_en ? dq_drv : 32'bz;

    // pending burst
    reg        wr_act = 0;
    reg [2:0]  wr_i;
    reg [20:0] wr_base;
    reg [3:0]  rd_q [0:3];         // scheduled read slots (col offset + valid)
    reg [20:0] rd_base;
    integer    rd_i = -1, rd_delay = 0;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    always @(posedge clk) if (cke) begin
        // ---- write data beats ----
        if (wr_act) begin
            mem[wr_base + wr_i] <= dq;
            if (wr_i == 3'd7) begin wr_act <= 0; row_open[wr_base[20:19]] <= 0; end
            wr_i <= wr_i + 3'd1;
        end
        // ---- read data beats (CL = 2) ----
        if (rd_delay > 0) begin
            rd_delay = rd_delay - 1;
            if (rd_delay == 0) rd_i = 0;
        end else if (rd_i >= 0) begin
            rd_i = rd_i + 1;
            if (rd_i == 8) rd_i = -1;
        end
        if (rd_i >= 0) begin
            #(T_AC) dq_drv = mem[rd_base + rd_i]; dq_en = 1;
        end else begin
            #(T_OH) dq_en = 0;
        end
    end

    always @(posedge clk) if (cke) begin
        case (cmd)
            4'b0000: begin                                   // MRS
                mode_ok = (addr[2:0] == 3'b011) && (addr[3] == 0) && (addr[6:4] == 3'b010);
                if (!mode_ok) begin errors = errors + 1; $display("SDRAM: bad mode %h", addr); end
            end
            4'b0011: begin                                   // ACT
                if (row_open[ba]) begin errors = errors + 1; $display("SDRAM: ACT on open bank %0d", ba); end
                row_open[ba] = 1; open_row[ba] = addr;
            end
            4'b0100: begin                                   // WRITE
                if (!row_open[ba] || !mode_ok) begin errors = errors + 1; $display("SDRAM: WRITE bank %0d not open", ba); end
                if (addr[2:0] != 0 || !addr[10]) begin errors = errors + 1; $display("SDRAM: WRITE col/AP %h", addr); end
                wr_base = {ba, open_row[ba], addr[7:0]};
                mem[wr_base] <= dq; wr_i <= 3'd1; wr_act <= 1; writes = writes + 1;
            end
            4'b0101: begin                                   // READ
                if (!row_open[ba] || !mode_ok) begin errors = errors + 1; $display("SDRAM: READ bank %0d not open", ba); end
                rd_base = {ba, open_row[ba], addr[7:0]};
                rd_delay = 1;                                // data after the next edge (CL 2)
                row_open[ba] = 0;                            // auto-precharge (after the burst)
                reads = reads + 1;
            end
            4'b0010: for (i = 0; i < 4; i = i + 1) row_open[i] = 0;          // PRE all
            4'b0001: begin                                   // AUTO REFRESH
                for (i = 0; i < 4; i = i + 1)
                    if (row_open[i]) begin errors = errors + 1; $display("SDRAM: REF with open bank %0d", i); end
                refreshes = refreshes + 1;
            end
            default: ;
        endcase
    end
endmodule
