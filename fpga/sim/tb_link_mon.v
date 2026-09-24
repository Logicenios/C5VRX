// link_mon: synthetic 80 MS/s FM I/Q (rotating 4-bit phasor, radius 6 LSB, <= 0.6 rad per
// sample) whose bits are a random old/new mix within +-1 ns of each change; 40 MHz STROBE at
// a chosen phase. Checks: sample count per window, bit activity, and that the edge-placement
// counters separate "both edges mid-eye" from "rising edge on the transitions".
`timescale 1ps/1ps
module tb_link_mon;
    parameter integer PHASE_PS = 6250;       // rising STROBE edge position in the data period (0..12499)
    parameter EXPECT_BAD = 0;                // 1: the edge sits in the transition window
    reg lclk = 0; reg [7:0] d = 0; reg tog = 0;
    wire [25:0] samples, ep, en; wire [7:0] s0, s1, edges;
    reg [7:0] dp = 0;
    always @(posedge lclk) dp <= d;                            // top.v iq_cap
    link_mon dut (.lclk(lclk), .link_d(d), .dp_in(dp), .win_tog(tog), .samples(samples), .err_p(ep),
                  .err_n(en), .seen0(s0), .seen1(s1), .edges(edges));
    // data: new native sample every 12.5 ns; +-1 ns around each change the pins show a mix
    real ph = 0.0, w = 0.0; integer k, seed = 7; reg [7:0] nxt, cur = 0;
    function [3:0] q4(input real v);
        integer r; begin r = $rtoi(v + 8.5) - 8; if (r > 7) r = 7; if (r < -8) r = -8; q4 = r[3:0]; end
    endfunction
    initial begin
        forever begin
            w = w + 0.02 * ($random(seed) % 100) / 100.0; if (w > 0.6) w = 0.6; if (w < -0.6) w = -0.6;
            ph = ph + w;
            nxt = {q4(6.0 * $cos(ph)), q4(6.0 * $sin(ph))};
            #11500;                                            // stable part of the eye
            for (k = 0; k < 2; k = k + 1) begin d = cur ^ ((cur ^ nxt) & $random(seed)); #500; end
            cur = nxt; d = cur;
        end
    end
    // data period 12.5 ns: stable 0..11.5 ns, mixed 11.5..12.5 ns, then the new sample. The rising
    // STROBE edge sits PHASE_PS into that period (the falling edge 12.5 ns later: same phase)
    initial begin
        #(12500 + PHASE_PS);
        forever begin lclk = 1; #12500; lclk = 0; #12500; end
    end
    initial forever begin #100_000_000; tog = ~tog; end        // 100 us windows
    integer n;
    initial begin
        #650_000_000;
        $display("tb_link_mon PHASE_PS=%0d: samples/window %0d (expect 4000), err_p %0d, err_n %0d, seen0 %h seen1 %h %s",
                 PHASE_PS, samples, ep, en, s0, s1,
                 (samples == 4000 && s0 == 8'hFF && s1 == 8'hFF &&
                  (EXPECT_BAD ? (ep > 400 && en > 400) : (ep == 0 && en == 0))) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
