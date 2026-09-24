// Control plane: PicoRV32 + fpga/firmware against a scripted C5 (soc_stimulus.py) and
// scripted S1 presses. Logs the bytes the FPGA sends to the C5 and the final OSD text;
// check_soc.py decodes and checks both.
`timescale 1ns/1ps
module tb_soc;
    parameter integer QUICK_MS = 0;
    parameter RXFILE = "data/soc_rx.hex";
    parameter NOSIG = 0;                 // 1: board with no C5 attached (no strobe, no field, loss)      // > 0: stop after this many ms (boot check)
    parameter TXLOG = "data/soc_tx.txt";
    reg clk = 0;
    always #18.518 clk = ~clk;                 // 27 MHz
    reg  [3:0] rc = 4'hF; always @(posedge clk) if (rc != 0) rc <= rc - 4'd1;
    reg  rx = 1'b1; wire tx;
    reg  s1 = 0, s2 = 0;
    wire osd_we; wire [9:0] osd_waddr; wire [15:0] osd_wdata;
    wire [31:0] set0, set1, set2, osd_ctrl;
    soc #(.FW_HEX("../firmware/build/fw.hex")) dut (
        .clk(clk), .resetn(rc == 0), .uart_tx(tx), .uart_rx(rx),
        .osd_we(osd_we), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata),
        .status(NOSIG ? {20'd0, 1'b1, 1'b0, 2'd0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, s2, s1}
                       : {20'd0, 1'b0, 1'b1, 2'd1, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, s2, s1}),
        .meas_tip(32'd0), .meas_blank(32'd0), .counters(32'd0),
        .settings0(set0), .settings1(set1), .settings2(set2), .osd_ctrl(osd_ctrl));

    // OSD text mirror
    reg [15:0] text [0:1023];
    integer i;
    initial for (i = 0; i < 1024; i = i + 1) text[i] = 16'h0020;
    always @(posedge clk) if (osd_we) text[osd_waddr] <= osd_wdata;

    // C5 -> FPGA bytes at scripted times: a clocked player (27 clocks per bit = 1 Mbaud), so
    // Icarus and Verilator behave the same. Event file: one {time_us, byte} word per line.
    reg [39:0] ev [0:4095];
    integer nev = 0, e;
    initial begin
        for (e = 0; e < 4096; e = e + 1) ev[e] = 40'hFFFF_FFFF_FF;     // end marker
        $readmemh(RXFILE, ev);
        nev = 0;
        for (e = 0; e < 4096; e = e + 1) if (ev[e] != 40'hFFFF_FFFF_FF && nev == e) nev = e + 1;
    end
    reg [63:0] cyc = 0;
    integer pj = 0, pbit = 0, pdiv = 0;
    reg [9:0] psh = 10'h3FF;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (pbit == 0) begin
            rx <= 1'b1;
            if (pj < nev && cyc >= ev[pj][39:8] * 27) begin
                psh <= {1'b1, ev[pj][7:0], 1'b0}; pbit <= 10; pdiv <= 0; pj <= pj + 1;
            end
        end else begin
            rx <= psh[0];
            if (pdiv == 26) begin pdiv <= 0; psh <= {1'b1, psh[9:1]}; pbit <= pbit - 1; end
            else pdiv <= pdiv + 1;
        end
    end

    // FPGA -> C5 bytes
    integer fo_tx, k2; reg [7:0] rb;
    initial fo_tx = $fopen(TXLOG, "w");
    integer n_osd = 0, n_fall = 0;
    always @(negedge rx) n_fall = n_fall + 1;
    always @(posedge clk) if (osd_we) n_osd = n_osd + 1;
    initial if (QUICK_MS > 0) begin
        #(QUICK_MS * 1_000_000);
        $display("quick stop: %0d OSD writes, pc=%h, osd_ctrl=%h, rx wp=%0d rp=%0d ovf=%0d, events %0d, rx pin falls %0d, played %0d, ev0 %h", n_osd, dut.u_cpu.reg_pc, osd_ctrl, dut.u_uart.wp, dut.u_uart.rp, dut.u_uart.rx_overflow, nev, n_fall, pj, ev[0]);
        $finish;
    end
    always @(negedge tx) begin
        #1500;                                      // middle of bit 0
        for (k2 = 0; k2 < 8; k2 = k2 + 1) begin rb[k2] = tx; #1000; end
        $fwrite(fo_tx, "%0d %02x\n", $time / 1000000, rb); $fflush(fo_tx);
    end

    // buttons (ms): S1 short at 300 and 450 (open menu, next item = Scan), S1 long from
    // 600 (fires at 1300: start scan), S1 short at 1850 (tune the best channel)
    initial begin
        #300_000_000 s1 = 1; #60_000_000 s1 = 0;
        #90_000_000  s1 = 1; #60_000_000 s1 = 0;
        #90_000_000  s1 = 1; #900_000_000 s1 = 0;
        #350_000_000 s1 = 1; #60_000_000 s1 = 0;
        #440_000_000;                            // > one 5 Hz redraw after the last STATUS
        dump;
        $display("tb_soc: set0=%h set1=%h set2=%h osd=%h", set0, set1, set2, osd_ctrl);
        $fclose(fo_tx);
        $finish;
    end
    task dump;
        integer r, c, fo; reg [7:0] ch;
        begin
            fo = $fopen("data/soc_osd.txt", "w");
            for (r = 0; r < 16; r = r + 1) begin
                for (c = 0; c < 40; c = c + 1) begin
                    ch = text[r * 64 + c][7:0];
                    $fwrite(fo, "%c", (ch >= 8'h20 && ch < 8'h7f) ? ch : (ch == 0 ? 8'h20 : 8'h23));
                end
                $fwrite(fo, "|%02x\n", text[r * 64][15:8]);
            end
            $fclose(fo);
        end
    endtask
endmodule
