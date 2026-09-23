// Y/C separation and colour demodulation on the 1280-point line-locked grid (THEORY §11).
// Bit-exact with fpga/model/chroma_ref.py chroma_decode().
//
//  * NCO: 16-bit phase, NTSC 11648 (91/512 turn), PAL 14528 (227/1024 turn) per sample.
//  * Burst: products over x in [112,144); decision (PAL V-switch, colour killer) at x = 150;
//    NCO phase correction applied at the end of the line.
//  * Y/C: comb (NTSC 1H, PAL 2H) or notch (2x - x[-2] - x[+2]) / 4.
//  * Demod: U = LPF(C sin), V = LPF(C cos), two boxcars (8, 6), x sat >> 20, PAL-D average.
// Output lags the input by 2 samples (continuous across lines).
`default_nettype none
module chroma_dec #(
    parameter SIN_FILE = "sin_lut.hex",
    parameter COS_FILE = "cos_lut.hex"
) (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [11:0] cv,
    input  wire               cv_valid,
    input  wire [10:0]        cv_x,
    input  wire               is_pal,
    input  wire               comb,         // 1 = comb, 0 = notch
    input  wire [15:0]        hue,          // NTSC hue offset (1/65536 turn)
    input  wire [7:0]         sat,          // 146 = nominal
    output reg  signed [11:0] y_out,
    output reg  signed [15:0] u_out,
    output reg  signed [15:0] v_out,
    output reg  [10:0]        x_out,
    output reg                out_valid,
    output reg                killed,
    output reg                pal_sw_neg
);
    localparam integer LS = 1280;
    localparam [10:0] BX0 = 11'd112, BX1 = 11'd144, BDEC = 11'd150, XACT0 = 11'd160;
    localparam signed [31:0] KILL_BU = 32'sd60000;

    reg signed [9:0] sin_rom [0:255];
    reg signed [9:0] cos_rom [0:255];

    wire [15:0] inc = is_pal ? 16'd14528 : 16'd11648;

    // ---------------- NCO ----------------
    reg [15:0] phi_line, phi_run;
    wire [15:0] phi_in = (cv_x == 0) ? phi_line : phi_run + inc;

    // ---------------- line buffers: 1H and 2H composite delay ----------------
    reg signed [11:0] lb1 [0:LS-1];
    reg signed [11:0] lb2 [0:LS-1];
    reg signed [11:0] d1_q, d2_q;

    // ---------------- burst ----------------
    reg signed [31:0] bu, bv, bv_prev;
    reg [3:0]  kill_cnt;
    wire [7:0] kb = phi_in[15:8];
    wire signed [21:0] b_s = cv * sin_rom[kb];
    wire signed [21:0] b_c = cv * cos_rom[kb];

    wire signed [32:0] err = is_pal ? (bv + bv_prev) : {bv[31], bv};
    wire signed [32:0] err_sh = err >>> 9;
    wire [15:0] corr16 = (-err_sh[15:0]) + ((bu > 0) ? 16'd32768 : 16'd0);

    // ---------------- stage A register (input sample) ----------------
    reg signed [11:0] a_cv;
    reg [15:0] a_phi;
    reg [10:0] a_x;
    reg        a_v;
    always @(posedge clk) begin
        a_v <= 1'b0;
        if (rst) begin
            phi_line <= 0; phi_run <= 0; bu <= 0; bv <= 0; bv_prev <= 0; kill_cnt <= 0;
            killed <= 1'b0; pal_sw_neg <= 1'b0;
        end else if (cv_valid) begin
            phi_run <= phi_in;
            a_cv <= cv; a_phi <= phi_in; a_x <= cv_x; a_v <= 1'b1;
            d1_q <= lb1[cv_x]; d2_q <= lb2[cv_x];
            lb1[cv_x] <= cv;
            lb2[cv_x] <= lb1[cv_x];
            if (cv_x == BX0) begin bu <= b_s; bv <= b_c; end
            else if (cv_x > BX0 && cv_x < BX1) begin bu <= bu + b_s; bv <= bv + b_c; end
            if (cv_x == BDEC) begin
                pal_sw_neg <= is_pal && (bv < 0);
                if ((bu < 0 ? -bu : bu) < KILL_BU) begin
                    kill_cnt <= (kill_cnt == 4'd8) ? 4'd8 : kill_cnt + 4'd1;
                    killed <= (kill_cnt >= 4'd7);
                end else begin
                    kill_cnt <= (kill_cnt == 4'd0) ? 4'd0 : kill_cnt - 4'd1;
                    killed <= (kill_cnt >= 4'd9);   // i.e. (kill_cnt-1) >= 8: never
                end
            end
            if (cv_x == LS - 1) begin
                // corr = -(err >> 9) (+ half turn if bu > 0), err = bv (+ bv_prev for PAL)
                phi_line <= phi_line + inc * 16'd1280 + corr16;
                bv_prev <= bv;
            end
        end
    end

    // ---------------- stage B: separation + mixer (centre = s[1] after the shift) ----------------
    // When a_v shifts, the new centre sample is s_*[1] (old s[0]); its neighbours are
    // x-1 = s[2] (old s[1]) ... for the notch we need x-2 and x+2: use a 5-tap window.
    reg signed [11:0] w [0:4];
    reg [15:0] w_phi [0:4];
    reg signed [11:0] w_dl [0:4];
    reg [10:0] w_x [0:4];
    reg [2:0]  w_n;
    reg        w_v;
    integer i, i2, i3;
    always @(posedge clk) begin
        w_v <= 1'b0;
        if (rst) begin
            w_n <= 0;
            for (i = 0; i < 5; i = i + 1) begin w[i] <= 0; w_phi[i] <= 0; w_dl[i] <= 0; w_x[i] <= 0; end
        end
        else if (a_v) begin
            w[0] <= a_cv; w_phi[0] <= a_phi; w_dl[0] <= is_pal ? d2_q : d1_q; w_x[0] <= a_x;
            for (i = 1; i < 5; i = i + 1) begin
                w[i] <= w[i-1]; w_phi[i] <= w_phi[i-1]; w_dl[i] <= w_dl[i-1]; w_x[i] <= w_x[i-1];
            end
            if (w_n != 3'd5) w_n <= w_n + 3'd1;
            w_v <= (w_n >= 3'd2);
        end
    end
    // after the shift, centre (x - 2 relative to newest) is w[2]
    wire signed [13:0] notch_c = ($signed({w[2], 1'b0}) - w[0] - w[4]) >>> 2;
    wire signed [12:0] comb_c  = ($signed(w[2]) - $signed(w_dl[2])) >>> 1;
    wire signed [12:0] ch      = comb ? comb_c : notch_c[12:0];
    wire [7:0] kd = (w_phi[2] + hue) >> 8;
    reg signed [22:0] m_u, m_v;
    reg signed [12:0] y_b;
    reg [10:0] x_b;
    reg        v_b;
    always @(posedge clk) begin
        v_b <= w_v;
        if (w_v) begin
            m_u <= ch * sin_rom[kd];
            m_v <= ch * cos_rom[kd];
            y_b <= $signed(w[2]) - ch;
            x_b <= w_x[2];
        end
    end

    // ---------------- boxcars (8 then 6), reset per line at x == 0 ----------------
    reg signed [22:0] bu1 [0:7];
    reg signed [22:0] bv1 [0:7];
    reg signed [25:0] su1, sv1;
    reg signed [25:0] bu2 [0:5];
    reg signed [25:0] bv2 [0:5];
    reg signed [28:0] su2, sv2;
    reg signed [12:0] y_c, y_d;
    reg [10:0] x_c, x_d;
    reg        v_c, v_d;
    wire first = (x_b == 0);
    wire signed [25:0] su1_n = (first ? 26'sd0 : su1 - bu1[7]) + m_u;
    wire signed [25:0] sv1_n = (first ? 26'sd0 : sv1 - bv1[7]) + m_v;
    always @(posedge clk) begin
        v_c <= v_b;
        if (v_b) begin
            su1 <= su1_n; sv1 <= sv1_n;
            bu1[0] <= m_u; bv1[0] <= m_v;
            for (i2 = 1; i2 < 8; i2 = i2 + 1) begin
                bu1[i2] <= first ? 23'sd0 : bu1[i2-1];
                bv1[i2] <= first ? 23'sd0 : bv1[i2-1];
            end
            y_c <= y_b; x_c <= x_b;
        end
    end
    wire first_c = (x_c == 0);
    wire signed [28:0] su2_n = (first_c ? 29'sd0 : su2 - bu2[5]) + su1;
    wire signed [28:0] sv2_n = (first_c ? 29'sd0 : sv2 - bv2[5]) + sv1;
    always @(posedge clk) begin
        v_d <= v_c;
        if (v_c) begin
            su2 <= su2_n; sv2 <= sv2_n;
            bu2[0] <= su1; bv2[0] <= sv1;
            for (i3 = 1; i3 < 6; i3 = i3 + 1) begin
                bu2[i3] <= first_c ? 26'sd0 : bu2[i3-1];
                bv2[i3] <= first_c ? 26'sd0 : bv2[i3-1];
            end
            y_d <= y_c; x_d <= x_c;
        end
    end

    // ---------------- saturation, V switch, gating, PAL-D average ----------------
    wire signed [37:0] us = su2 * $signed({1'b0, sat});
    wire signed [37:0] vs = sv2 * $signed({1'b0, sat});
    wire signed [17:0] uo0 = us >>> 20;
    wire signed [17:0] vo1 = vs >>> 20;
    wire signed [17:0] vo0 = pal_sw_neg ? -vo1 : vo1;
    wire gate = (x_d < XACT0) || killed;
    wire signed [17:0] uo = gate ? 18'sd0 : uo0;
    wire signed [17:0] vo = gate ? 18'sd0 : vo0;
    reg signed [17:0] pu [0:LS-1];
    reg signed [17:0] pv [0:LS-1];
    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (v_d) begin
            if (is_pal) begin
                u_out <= (uo + pu[x_d]) >>> 1;
                v_out <= (vo + pv[x_d]) >>> 1;
                pu[x_d] <= uo; pv[x_d] <= vo;
            end else begin
                u_out <= uo[15:0]; v_out <= vo[15:0];
            end
            y_out <= y_d[11:0];
            x_out <= x_d;
            out_valid <= 1'b1;
        end
    end
    integer n;
    initial begin
        $readmemh(SIN_FILE, sin_rom); $readmemh(COS_FILE, cos_rom);
        // BSRAM powers up zeroed in the bitstream; mirror that for simulation
        for (n = 0; n < 1280; n = n + 1) begin lb1[n] = 0; lb2[n] = 0; pu[n] = 0; pv[n] = 0; end
    end
endmodule
`default_nettype wire
