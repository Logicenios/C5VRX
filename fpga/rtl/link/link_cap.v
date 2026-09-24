// Raw sample capture for link bring-up: after a request from the CPU (toggle, crystal domain)
// the next DEPTH STROBE cycles are stored as {falling-edge byte, rising-edge byte}, i.e. two
// consecutive native modem samples per word when both edges sit in the data eye. The CPU
// reads the buffer back through a second (crystal-clock) port once `done` has toggled.
`default_nettype none
module link_cap #(
    parameter integer AW = 11                // 2048 words
) (
    input  wire          lclk,
    input  wire [7:0]    dp,                 // rising-edge capture (top.v iq_cap)
    input  wire [7:0]    dn,                 // falling-edge capture, retimed (link_mon dn_raw)
    input  wire          req_tog,            // crystal domain: toggle to start a capture
    output reg           done_tog = 1'b0,    // lclk domain: toggles when the buffer is full
    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output reg  [15:0]   rdata
);
    (* ram_style = "block" *) reg [15:0] mem [0:(1 << AW) - 1];
    reg [2:0] rs = 0; reg run = 1'b0; reg [AW-1:0] wa = 0;
    always @(posedge lclk) begin
        rs <= {rs[1:0], req_tog};
        if (rs[2] ^ rs[1]) begin run <= 1'b1; wa <= 0; end
        else if (run) begin
            mem[wa] <= {dn, dp};
            wa <= wa + 1'b1;
            if (&wa) begin run <= 1'b0; done_tog <= ~done_tog; end
        end
    end
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
`default_nettype wire
