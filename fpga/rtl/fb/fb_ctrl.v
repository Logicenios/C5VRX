// Frame-buffer controller (pixel clock domain, same clock as the SDRAM and the scaler).
//
// Layout (32-bit words): field buffer b (0..4) at b * 147456 (288 lines x 512-word pitch =
// 2 SDRAM rows per line); a line is 360 words (720 px, 4:2:2 {Cr, Y1, Cb, Y0}).
//
// Buffering: the writer fills wbuf. When the next field starts it publishes wbuf as
// `newest` (the previous newest becomes `prev`) and takes a buffer that is none of newest,
// prev and the two the reader holds. At each output frame event the reader latches
// rb0 = newest and rb1 = prev (bob uses rb0; weave uses both), so a field is never read
// while it is written and the newest complete field is always shown. Five buffers are
// needed: with weave the reader holds two, and at 59.94 -> 50 Hz the writer can publish
// twice between frame events.
`default_nettype none
module fb_ctrl (
    input  wire        clk,
    input  wire        rst,
    // input FIFO (FWFT)
    input  wire [35:0] fifo_data,
    input  wire        fifo_empty,
    input  wire [9:0]  fifo_level,
    output wire        fifo_pop,
    // SDRAM controller
    output reg         sd_req,
    output reg         sd_we,
    output reg  [20:0] sd_addr,
    input  wire        sd_ack,
    input  wire        sd_wd_pop,
    input  wire [31:0] sd_rdata,
    input  wire        sd_rd_valid,
    input  wire        sd_ready,
    // reader side (scaler)
    input  wire        frame_evt,          // output frame event (vertical blanking)
    input  wire        req,                // fetch line req_line of field rb0/rb1 into slot req_slot
    input  wire [8:0]  req_line,
    input  wire        req_prev,           // 1 = rb1 (previous field)
    input  wire [2:0]  req_slot,
    output reg         done,               // one pulse when the fetch completed
    output reg         busy,
    // latched at frame_evt (stable for a whole output frame)
    output reg         cur_odd,            // rb0 is the odd (top) field
    output reg         cur_pal,
    output reg         cur_valid,          // rb0 holds a complete field
    output reg         prev_valid,         // rb1 holds a complete field of the same standard
    output reg  [7:0]  field_count,        // increments per completed field (signal-loss detection)
    // line-cache write port
    output reg         lc_we,
    output reg  [2:0]  lc_slot,
    output reg  [8:0]  lc_word,
    output reg  [31:0] lc_wdata,
    output wire [7:0]  dbg             // {w_line, w_inflight, r_pend, r_active, r_inflight, sd_req, w_started, have_newest}
);
    function [20:0] buf_base(input [2:0] b);
        case (b)
            3'd0: buf_base = 21'd0;
            3'd1: buf_base = 21'd147456;
            3'd2: buf_base = 21'd294912;
            3'd3: buf_base = 21'd442368;
            default: buf_base = 21'd589824;
        endcase
    endfunction
    // lowest-numbered buffer not in {a, b, c, d}
    function [2:0] free4(input [2:0] a, input [2:0] b, input [2:0] c, input [2:0] d);
        integer i;
        begin
            free4 = 3'd4;
            for (i = 4; i >= 0; i = i - 1)
                if (a != i && b != i && c != i && d != i) free4 = i;
        end
    endfunction

    // ---- buffer ownership ----
    reg [2:0] wbuf, newest, prev, rb0, rb1;
    reg       have_newest, have_prev, w_odd, w_pal, n_odd, n_pal, p_pal, w_any;
    reg       w_started;               // the current field's first line was seen (no partial fields)

    // ---- writer ----
    reg        w_line;
    reg [8:0]  w_lineno;
    reg [5:0]  w_burst;                // 0..44
    reg        w_inflight;
    reg [3:0]  w_left;
    wire head_desc = !fifo_empty && fifo_data[35];
    // pop descriptors when not in a line; pop pixel words as the SDRAM consumes them
    // (orphan pixel words outside a line are discarded so the FIFO can never wedge)
    assign fifo_pop = (!w_line && !fifo_empty) || (w_inflight && sd_wd_pop);

    // ---- reader ----
    reg        r_pend, r_active, r_inflight;
    reg [8:0]  r_line;
    reg        r_prev;
    reg [5:0]  r_burst;
    reg [8:0]  r_word;
    assign dbg = {w_line, w_inflight, r_pend, r_active, r_inflight, sd_req, w_started, have_newest};

    always @(posedge clk) begin
        lc_we <= 1'b0;
        done <= 1'b0;
        if (rst || !sd_ready) begin
            wbuf <= 3'd0; newest <= 3'd1; prev <= 3'd2; rb0 <= 3'd1; rb1 <= 3'd2;
            have_newest <= 1'b0; have_prev <= 1'b0; w_any <= 1'b0; w_started <= 1'b0;
            w_line <= 1'b0; w_inflight <= 1'b0; r_pend <= 1'b0; r_active <= 1'b0; r_inflight <= 1'b0;
            sd_req <= 1'b0; busy <= 1'b0; cur_valid <= 1'b0; prev_valid <= 1'b0; field_count <= 0;
            cur_odd <= 1'b0; cur_pal <= 1'b0;
        end else begin
            if (frame_evt) begin
                rb0 <= newest; rb1 <= prev;
                cur_odd <= n_odd; cur_pal <= n_pal; cur_valid <= have_newest;
                prev_valid <= have_prev && (p_pal == n_pal);
            end
            if (req) begin r_pend <= 1'b1; busy <= 1'b1; r_line <= req_line; r_prev <= req_prev; lc_slot <= req_slot; end

            // a descriptor at the head while still inside a line: the line arrived short (the
            // resampler restarted it early on a real signal, or the FIFO dropped words while
            // full). Close the line so the descriptor is handled; without this the writer waits
            // for pixel words that never come and the FIFO wedges (hardware: fields frozen,
            // FIFO overflowing; MEASUREMENTS M71).
            if (w_line && head_desc && !w_inflight && !sd_req) w_line <= 1'b0;

            // descriptor handling
            if (!w_line && head_desc) begin
                if (fifo_data[34]) w_started <= 1'b1;
                if (fifo_data[34] && w_any && w_started) begin
                    // start of a new field: publish the finished one, take a free buffer
                    newest <= wbuf; n_odd <= w_odd; n_pal <= w_pal; have_newest <= 1'b1;
                    prev <= newest; p_pal <= n_pal; have_prev <= have_newest;
                    wbuf <= free4(wbuf, newest, frame_evt ? newest : rb0, frame_evt ? prev : rb1);
                    field_count <= field_count + 8'd1;
                end
                if (fifo_data[34]) w_any <= 1'b0;
                w_odd <= fifo_data[33]; w_pal <= fifo_data[32];
                w_lineno <= fifo_data[8:0];
                w_line <= (fifo_data[8:0] < 9'd288);
                w_burst <= 0;
            end

            // SDRAM requests: a write burst whenever 8 pixel words are queued, else reads
            if (!sd_req && !w_inflight && !r_inflight) begin
                if (w_line && fifo_level >= 10'd8 && !head_desc) begin
                    sd_req <= 1'b1; sd_we <= 1'b1;
                    sd_addr <= buf_base(wbuf) + {w_lineno, 9'd0} + {12'd0, w_burst, 3'd0};
                end else if (r_pend || r_active) begin
                    if (!r_active) begin r_active <= 1'b1; r_pend <= 1'b0; r_burst <= 0; r_word <= 0; end
                    sd_req <= 1'b1; sd_we <= 1'b0;
                    sd_addr <= buf_base(r_prev ? rb1 : rb0) + {r_line, 9'd0} + {12'd0, r_active ? r_burst : 6'd0, 3'd0};
                end
            end
            if (sd_req && sd_ack) begin
                sd_req <= 1'b0;
                if (sd_we) begin w_inflight <= 1'b1; w_left <= 4'd8; end
                else r_inflight <= 1'b1;
            end
            if (w_inflight && sd_wd_pop) begin
                w_left <= w_left - 4'd1;
                if (w_left == 4'd1) begin
                    w_inflight <= 1'b0;
                    w_any <= 1'b1;
                    if (w_burst == 6'd44) w_line <= 1'b0; else w_burst <= w_burst + 6'd1;
                end
            end
            if (r_inflight && sd_rd_valid) begin
                lc_we <= 1'b1; lc_word <= r_word; lc_wdata <= sd_rdata;
                r_word <= r_word + 9'd1;
                if (r_word[2:0] == 3'd7) begin
                    r_inflight <= 1'b0;
                    if (r_burst == 6'd44) begin r_active <= 1'b0; done <= 1'b1; busy <= r_pend; end
                    else r_burst <= r_burst + 6'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
