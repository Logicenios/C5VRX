// Colour-lock recorder: 256 consecutive lines of chroma_dec's burst loop, one block RAM
// (MEASUREMENTS M79). After a request from the CPU (toggle, crystal domain) the next 256 line
// records are stored, then `done_tog` toggles and the CPU reads them back through a second
// (crystal-clock) port. Observation only: nothing here feeds back into the decoder.
//   word 2n:   {burst U >>> 8, burst V >>> 8}                          (saturated, signed)
//   word 2n+1: {NCO correction[15:0], H sync edge error[11:0] (1/16 sample), flags[3:0]}
//              flags = {180-degree flip (bu > 0), V switch, colour killer, field start seen}
`default_nettype none
module chroma_log (
    input  wire        clk,                  // receive (pixel) clock
    input  wire        rec_we,               // one clock per line (chroma_dec log_we)
    input  wire [15:0] bu,
    input  wire [15:0] bv,
    input  wire [15:0] corr,
    input  wire [11:0] perr,
    input  wire [2:0]  fl,
    input  wire        field_start,          // video_timing field_start (any time in the line)
    input  wire        req_tog,              // crystal domain: toggle to start a recording
    output reg         done_tog = 1'b0,      // clk domain: toggles when 256 lines are stored
    input  wire        rclk,
    input  wire [8:0]  raddr,                // word address
    output reg  [31:0] rdata
);
    (* ram_style = "block" *) reg [31:0] mem [0:511];
    reg [2:0] rs = 0; reg run = 1'b0; reg [7:0] line = 0; reg fs_seen = 1'b0;
    reg       w2 = 1'b0; reg [31:0] w2d;
    reg       wr = 1'b0; reg [8:0] wa; reg [31:0] wd;       // single write port (block RAM)
    always @(posedge clk) begin
        rs <= {rs[1:0], req_tog};
        wr <= 1'b0;
        if (field_start) fs_seen <= 1'b1;
        if (rs[2] ^ rs[1]) begin
            run <= 1'b1; line <= 0; w2 <= 1'b0; fs_seen <= 1'b0;
        end else if (run && rec_we) begin
            // two words per record, written on consecutive clocks (records are a line apart)
            wr <= 1'b1; wa <= {line, 1'b0}; wd <= {bu, bv};
            w2 <= 1'b1; w2d <= {corr, perr, fl, fs_seen || field_start};
            fs_seen <= 1'b0;
        end else if (w2) begin
            wr <= 1'b1; wa <= {line, 1'b1}; wd <= w2d; w2 <= 1'b0;
            line <= line + 8'd1;
            if (&line) begin run <= 1'b0; done_tog <= ~done_tog; end
        end
    end
    always @(posedge clk) if (wr) mem[wa] <= wd;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
`default_nettype wire
