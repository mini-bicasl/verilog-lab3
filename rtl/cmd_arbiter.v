// cmd_arbiter.v – DDR4 Command Arbiter
//
// Arbitrates between read and write request queues from the AXI slave and
// forwards the selected request to cmd_scheduler using a valid/ready handshake.
//
// Refresh preemption (ref_req from refresh_ctrl):
//   When ref_req is asserted the arbiter stops forwarding new commands to the
//   scheduler.  Any in-flight S_BUSY transaction is allowed to complete first.
//
// Priority policy (parameter RD_PRIORITY):
//   1 = reads preferred over writes when both are pending (default)
//   0 = writes preferred over reads when both are pending
//
// Upstream handshake:
//   rd_ready / wr_ready are single-cycle accept pulses on the cycle the request
//   is latched.  Only one of rd_ready or wr_ready is asserted per cycle.
//
// Downstream handshake:
//   arb_valid is held high until arb_ready is observed from cmd_scheduler.
//
// Reset: active-low asynchronous (negedge rst_n in sensitivity list).
//
// Compile & run:
//   iverilog -g2012 -o build/cmd_arbiter.out tb/cmd_arbiter_tb.v rtl/cmd_arbiter.v
//   vvp build/cmd_arbiter.out

`default_nettype none

module cmd_arbiter #(
    parameter AXI_ADDR_W  = 34,
    parameter AXI_ID_W    = 8,
    parameter RD_PRIORITY = 1    // 1 = reads preferred; 0 = writes preferred
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Refresh preemption (from refresh_ctrl) – highest priority
    input  wire                  ref_req,     // 1 = block new downstream commands

    // Read request channel (from upstream / axi4_slave)
    input  wire                  rd_valid,
    output reg                   rd_ready,
    input  wire [AXI_ADDR_W-1:0] rd_addr,
    input  wire [AXI_ID_W-1:0]   rd_id,

    // Write request channel (from upstream / axi4_slave)
    input  wire                  wr_valid,
    output reg                   wr_ready,
    input  wire [AXI_ADDR_W-1:0] wr_addr,
    input  wire [AXI_ID_W-1:0]   wr_id,

    // Arbitrated output to cmd_scheduler (valid/ready handshake)
    output reg                   arb_valid,
    input  wire                  arb_ready,
    output reg                   arb_is_write,
    output reg  [AXI_ADDR_W-1:0] arb_addr,
    output reg  [AXI_ID_W-1:0]   arb_id
);

    // ---------------------------------------------------------------
    // FSM state encodings
    // ---------------------------------------------------------------
    localparam S_IDLE = 1'b0;   // no active downstream transaction
    localparam S_BUSY = 1'b1;   // holding arb_valid until arb_ready seen

    reg state;

    // ---------------------------------------------------------------
    // Grant selection – combinational, active only in IDLE
    //
    // prefer_rd is a parameter-derived constant; the synthesizer will
    // eliminate the dead branch entirely.
    // ---------------------------------------------------------------
    wire prefer_rd = (RD_PRIORITY == 1) ? 1'b1 : 1'b0;

    wire can_arb  = (state == S_IDLE) && !ref_req;
    wire grant_rd = can_arb &&  rd_valid && (!wr_valid ||  prefer_rd);
    wire grant_wr = can_arb &&  wr_valid && (!rd_valid || !prefer_rd);

    // ---------------------------------------------------------------
    // Sequential FSM (active-low async reset)
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            arb_valid    <= 1'b0;
            arb_is_write <= 1'b0;
            arb_addr     <= {AXI_ADDR_W{1'b0}};
            arb_id       <= {AXI_ID_W{1'b0}};
            rd_ready     <= 1'b0;
            wr_ready     <= 1'b0;
        end else begin
            // Default: clear single-cycle accept pulses
            rd_ready <= 1'b0;
            wr_ready <= 1'b0;

            case (state)

                // ---------------------------------------------------
                // IDLE: no active downstream transaction.
                // Accept rd or wr if available and refresh permits.
                // ---------------------------------------------------
                S_IDLE: begin
                    arb_valid <= 1'b0;
                    if (grant_rd) begin
                        arb_valid    <= 1'b1;
                        arb_is_write <= 1'b0;
                        arb_addr     <= rd_addr;
                        arb_id       <= rd_id;
                        rd_ready     <= 1'b1;
                        state        <= S_BUSY;
                    end else if (grant_wr) begin
                        arb_valid    <= 1'b1;
                        arb_is_write <= 1'b1;
                        arb_addr     <= wr_addr;
                        arb_id       <= wr_id;
                        wr_ready     <= 1'b1;
                        state        <= S_BUSY;
                    end
                end

                // ---------------------------------------------------
                // BUSY: forwarding request downstream.
                // Hold arb_valid until arb_ready is observed.
                // ---------------------------------------------------
                S_BUSY: begin
                    if (arb_ready) begin
                        arb_valid <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
