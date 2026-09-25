// test_src -> fb_format: every field has 288 active line descriptors of 360 pixel words, and the
// centre pixel of each bar decodes to its 75 % BT.601 code (Y' / Cb / Cr within +-1).
`timescale 1ns/1ps
module tb_testsrc;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    wire signed [11:0] y; wire signed [15:0] u, v; wire [10:0] x; wire [9:0] line; wire valid, odd;
    test_src dut (.clk(clk), .rst(rst), .en(1'b1), .y(y), .u(u), .v(v), .x(x), .valid(valid), .line(line), .odd(odd));
    wire [35:0] fd; wire fw;
    fb_format fmt (.clk(clk), .rst(rst), .y_in(y), .u_in(u), .v_in(v), .x_in(x), .in_valid(valid),
        .tag_strobe(valid && x == 11'd0), .line_no(line), .field_odd(odd), .is_pal(1'b1), .locked(1'b1),
        .brightness(8'sd0), .contrast(8'd128), .fifo_data(fd), .fifo_wr(fw));

    // expected codes per bar (white, yellow, cyan, green, magenta, red, blue, black)
    integer ey [0:7], eb [0:7], er [0:7];
    initial begin
        ey[0]=180; eb[0]=128; er[0]=128;  ey[1]=161; eb[1]=44;  er[1]=142;
        ey[2]=131; eb[2]=156; er[2]=44;   ey[3]=112; eb[3]=72;  er[3]=58;
        ey[4]=84;  eb[4]=184; er[4]=198;  ey[5]=65;  eb[5]=100; er[5]=212;
        ey[6]=35;  eb[6]=212; er[6]=114;  ey[7]=16;  eb[7]=128; er[7]=128;
    end
    function integer absd(input integer a, input integer b); absd = (a > b) ? a - b : b - a; endfunction

    integer words = 0, lines = 0, fields = 0, errs = 0, desc_line = -1, lines_in_field = 0, k;
    always @(posedge clk) if (fw) begin
        if (fd[35]) begin
            if (desc_line >= 0 && words != 360) begin
                errs = errs + 1; if (errs < 8) $display("ERR line %0d had %0d words", desc_line, words);
            end
            if (fd[34]) begin
                if (fields > 0 && lines_in_field != 288) begin
                    errs = errs + 1; $display("ERR field had %0d active lines", lines_in_field);
                end
                fields = fields + 1; lines_in_field = 0;
            end
            desc_line = fd[8:0]; words = 0; lines = lines + 1; lines_in_field = lines_in_field + 1;
        end else begin
            // pixel pair index = words; bar b centre = pixel 90 b + 45 -> word 45 b + 22
            // (skip line 100's neighbourhood: the moving marker may be there)
            for (k = 0; k < 8; k = k + 1)
                if (words == 45 * k + 22 && desc_line > 150) begin
                    if (absd(fd[7:0], ey[k]) > 1 || absd(fd[15:8], eb[k]) > 1 || absd(fd[31:24], er[k]) > 1) begin
                        errs = errs + 1;
                        if (errs < 8) $display("ERR bar %0d line %0d: Y %0d Cb %0d Cr %0d, want %0d %0d %0d",
                                               k, desc_line, fd[7:0], fd[15:8], fd[31:24], ey[k], eb[k], er[k]);
                    end
                end
            words = words + 1;
        end
    end

    initial begin
        #100 rst = 0;
        wait (fields == 4);
        $display("tb_testsrc: fields %0d, lines %0d, errors %0d %s", fields, lines, errs, errs == 0 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
