// Yosys techmap: rewrite every signed $mul as an unsigned multiply plus sign corrections.
//
// Why: with the open-source Gowin flow (yosys synth_gowin + nextpnr-himbaechel + apicula),
// the GW2AR-18 DSP blocks return wrong products in their signed modes (~5 % of random
// operands), while unsigned x unsigned is exact (fpga/bringup/dsp_probe.v, MEASUREMENTS M68).
// For an N-bit A and M-bit B, with ua / ub their raw bit patterns and a_s / b_s their sign
// bits (0 for an unsigned operand):
//   A * B = ua*ub - a_s * (ub << N) - b_s * (ua << M) + a_s*b_s * 2^(N+M)
// The last term vanishes modulo 2^(N+M), and the true product always fits in N+M bits, so the
// result is exact after sign extension to Y_WIDTH. Unsigned multiplies are left untouched.
(* techmap_celltype = "$mul" *)
module _signed_mul_to_unsigned (A, B, Y);
    parameter A_SIGNED = 0;
    parameter B_SIGNED = 0;
    parameter A_WIDTH = 1;
    parameter B_WIDTH = 1;
    parameter Y_WIDTH = 1;
    input  [A_WIDTH-1:0] A;
    input  [B_WIDTH-1:0] B;
    output [Y_WIDTH-1:0] Y;
    parameter [A_WIDTH-1:0] _TECHMAP_CONSTMSK_A_ = 0;
    parameter [A_WIDTH-1:0] _TECHMAP_CONSTVAL_A_ = 0;
    parameter [B_WIDTH-1:0] _TECHMAP_CONSTMSK_B_ = 0;
    parameter [B_WIDTH-1:0] _TECHMAP_CONSTVAL_B_ = 0;
    localparam integer N = A_WIDTH, M = B_WIDTH, P = A_WIDTH + B_WIDTH;
    // set bits of |C| for a constant operand (the adders a shift-and-add would need)
    function integer kbits(input integer w, input [63:0] v, input sgn);
        integer i; reg [64:0] m;
        begin
            m = (sgn && v[w-1]) ? (~{1'b1, v} + 65'd1) : {1'b0, v};
            if (sgn && v[w-1]) for (i = w; i < 65; i = i + 1) m[i] = 1'b0;
            kbits = 0;
            for (i = 0; i < 65; i = i + 1) if (i <= w) kbits = kbits + m[i];
        end
    endfunction
    // Constant operand with at most KMAX set bits in |C|: shift-and-add, KMAX adders, no DSP.
    // KMAX = 5 moves the output colour matrix (3-5 set bits, ~2 DSPs each with its 22-bit
    // operand) out of the DSP blocks: at ~90 % DSP use the placer could not legalise the
    // scaler's MULT9X9s (MEASUREMENTS M72). Denser constants stay on the DSP path, whose sign
    // corrections fold to (almost) nothing for a constant; a dense shift-and-add costs many LUTs.
    localparam integer KMAX = 5;
    localparam A_CONST = (&_TECHMAP_CONSTMSK_A_) && (A_WIDTH <= 64) &&
                         (kbits(A_WIDTH, _TECHMAP_CONSTVAL_A_, A_SIGNED) <= KMAX);
    localparam B_CONST = !A_CONST && (&_TECHMAP_CONSTMSK_B_) && (B_WIDTH <= 64) &&
                         (kbits(B_WIDTH, _TECHMAP_CONSTVAL_B_, B_SIGNED) <= KMAX);
    localparam SGN = A_SIGNED || B_SIGNED;
    generate
        if (A_CONST || B_CONST) begin : kmul
            // Constant operand (a coefficient): shift-and-add over the set bits of its magnitude,
            // negated for a negative constant. The additions for clear bits fold away, so this
            // costs popcount(|C|) adders and no DSP slot.
            localparam integer XW = A_CONST ? M : N, CW = A_CONST ? N : M;
            localparam        XS = A_CONST ? B_SIGNED : A_SIGNED, CS = A_CONST ? A_SIGNED : B_SIGNED;
            localparam [CW-1:0] CV = A_CONST ? _TECHMAP_CONSTVAL_A_ : _TECHMAP_CONSTVAL_B_;
            localparam        NEG = CS && CV[CW-1];
            localparam [CW:0] MAG = NEG ? (~{1'b1, CV} + 1'b1) : {1'b0, CV};
            wire [XW-1:0] xv = A_CONST ? B : A;
            wire [P-1:0]  xe = XS ? {{(P-XW){xv[XW-1]}}, xv} : {{(P-XW){1'b0}}, xv};
            wire [P*(CW+2)-1:0] acc;
            assign acc[P-1:0] = {P{1'b0}};
            genvar gk;
            for (gk = 0; gk <= CW; gk = gk + 1) begin : row
                if (MAG[gk]) begin : add
                    assign acc[P*(gk+1) +: P] = acc[P*gk +: P] + (xe << gk);
                end else begin : pass
                    assign acc[P*(gk+1) +: P] = acc[P*gk +: P];
                end
            end
            wire [P-1:0] kp = NEG ? (~acc[P*(CW+1) +: P] + 1'b1) : acc[P*(CW+1) +: P];
            if (Y_WIDTH <= P) begin : trunc
                assign Y = kp[Y_WIDTH-1:0];
            end else begin : ext
                assign Y = {{(Y_WIDTH - P){SGN ? kp[P-1] : 1'b0}}, kp};
            end
        end else if (!A_SIGNED && !B_SIGNED) begin : keep
            wire _TECHMAP_FAIL_ = 1'b1;
        end else begin : fix
            wire [P-1:0] ua = {{M{1'b0}}, A};
            wire [P-1:0] ub = {{N{1'b0}}, B};
            // Unsigned product, summed from 18 x 18 unsigned partial products, the proven DSP
            // case (a single wide product would be mapped to MULT36X36, which the placer does not
            // handle). SOFT = 1 builds it as shift-and-add logic instead (kept for DSP-bound
            // builds; costs LUTs).
            localparam SOFT = 0;
            localparam integer NA = (N + 17) / 18, NB = (M + 17) / 18;
            wire [18*NA-1:0] az = {{(18*NA-N){1'b0}}, A};
            wire [18*NB-1:0] bz = {{(18*NB-M){1'b0}}, B};
            wire [P-1:0] pu;
            if (SOFT) begin : soft
                wire [P*(M+1)-1:0] acc;                               // shift-and-add over B
                assign acc[P-1:0] = {P{1'b0}};
                genvar gk;
                for (gk = 0; gk < M; gk = gk + 1) begin : row
                    wire [P-1:0] ashift = ua << gk;
                    assign acc[P*(gk+1) +: P] = acc[P*gk +: P] + (B[gk] ? ashift : {P{1'b0}});
                end
                assign pu = acc[P*M +: P];
            end else begin : dsp
            // running sums as one flat vector (a wire array would become a memory)
            wire [P*(NA*NB+1)-1:0] part;
            assign part[P-1:0] = {P{1'b0}};
            genvar gi, gj;
            for (gi = 0; gi < NA; gi = gi + 1) begin : ga
                for (gj = 0; gj < NB; gj = gj + 1) begin : gb
                    wire [35:0] pp = az[18*gi +: 18] * bz[18*gj +: 18];
                    wire [P+36-1:0] sh = {{P{1'b0}}, pp} << (18 * (gi + gj));
                    assign part[P*(gi*NB + gj + 1) +: P] = part[P*(gi*NB + gj) +: P] + sh[P-1:0];
                end
            end
            assign pu = part[P*NA*NB +: P];
            end
            wire         a_s = A_SIGNED ? A[N-1] : 1'b0;
            wire         b_s = B_SIGNED ? B[M-1] : 1'b0;
            wire [P-1:0] ca = a_s ? (ub << N) : {P{1'b0}};
            wire [P-1:0] cb = b_s ? (ua << M) : {P{1'b0}};
            wire [P-1:0] ps = pu - ca - cb;
            if (Y_WIDTH <= P) begin : trunc
                assign Y = ps[Y_WIDTH-1:0];
            end else begin : ext
                assign Y = {{(Y_WIDTH - P){ps[P-1]}}, ps};
            end
        end
    endgenerate
endmodule
