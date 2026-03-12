// bank_fsm.v – Per-bank state machine for DDR4 controller
//
// Implements the four-state bank FSM described in docs/ARCHITECTURE.md §6.1:
//   IDLE -> ACTIVATING -> ACTIVE -> PRECHARGING -> IDLE
//
// Timing constraints enforced:
//   P_TRCD : cycles from ACT to first RD/WR (dwell time in ACTIVATING)
//   P_TRAS : minimum active time (ACT to earliest PRE); tRAS_timer tracks this
//   P_TRP  : precharge recovery time (dwell time in PRECHARGING)
//
// The tRAS timer starts simultaneously with the ACT command so it counts
// through both ACTIVATING and ACTIVE states.  A PRE command is accepted only
// when tras_ok is asserted (tras_cnt has reached 0).
//
// Interface (from docs/ARCHITECTURE.md §3.2):
//   cmd_in       [2:0]            – command: NOP/ACT/RD/WR/PRE/REF
//   row_addr_in  [ROW_ADDR_W-1:0] – row address carried with ACT
//   cmd_valid                     – command qualified this cycle
//   fsm_ready                     – bank FSM ready to accept a command
//   open_row     [ROW_ADDR_W-1:0] – currently open row (valid in ACTIVE)
//   row_active                    – 1 when in ACTIVE state
//   tras_ok                       – 1 when tRAS constraint satisfied
//   state_out    [1:0]            – raw state for debug
//
// Reset: active-low ASYNCHRONOUS (negedge rst_n in sensitivity list).
//
// Counter initialisation note:
//   trcd_cnt is loaded with (P_TRCD – 2) so that ACTIVATING lasts exactly
//   P_TRCD clock cycles before the FSM enters ACTIVE.
//   trp_cnt  is loaded with (P_TRP  – 2) so that PRECHARGING lasts exactly
//   P_TRP  clock cycles before the FSM returns to IDLE.
//   tras_cnt is loaded with (P_TRAS – 1) so that tras_ok asserts exactly
//   P_TRAS clock cycles after the ACT command.
//   Both P_TRCD and P_TRP must be >= 2 (satisfied by all DDR4 speed grades).
//
// Compile & run:
//   iverilog -g2012 -o build/bank_fsm.out tb/bank_fsm_tb.v rtl/bank_fsm.v
//   vvp build/bank_fsm.out

`default_nettype none

module bank_fsm #(
    parameter ROW_ADDR_W = 17,
    parameter P_TRCD     = 14,  // ACT-to-RD/WR delay (clock cycles, >= 2)
    parameter P_TRAS     = 52,  // Minimum active time (clock cycles)
    parameter P_TRP      = 14   // Precharge recovery time (clock cycles, >= 2)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Command interface (driven by cmd_scheduler)
    input  wire [2:0]            cmd_in,
    input  wire [ROW_ADDR_W-1:0] row_addr_in,
    input  wire                  cmd_valid,

    // Status / handshake outputs
    output reg                   fsm_ready,   // bank can accept a command
    output reg  [ROW_ADDR_W-1:0] open_row,    // open row address (valid in ACTIVE)
    output reg                   row_active,  // 1 when in ACTIVE state
    output wire                  tras_ok,     // 1 when tRAS constraint satisfied
    output reg  [1:0]            state_out    // current state (for debug)
);

    // ---------------------------------------------------------------
    // Command encodings (matches cmd_scheduler convention)
    // ---------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // ---------------------------------------------------------------
    // State encodings
    // ---------------------------------------------------------------
    localparam S_IDLE        = 2'd0;
    localparam S_ACTIVATING  = 2'd1;
    localparam S_ACTIVE      = 2'd2;
    localparam S_PRECHARGING = 2'd3;

    // ---------------------------------------------------------------
    // Pre-computed counter load values (localparams keep the math
    // in one place and avoid per-cycle parameter arithmetic)
    // ---------------------------------------------------------------
    localparam [7:0] INIT_TRCD = P_TRCD - 2;  // counts down to 0 in ACTIVATING
    localparam [7:0] INIT_TRAS = P_TRAS - 1;  // counts down to 0 across ACT+ACTIVE
    localparam [7:0] INIT_TRP  = P_TRP  - 2;  // counts down to 0 in PRECHARGING

    // ---------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------
    reg [1:0] state;
    reg [7:0] trcd_cnt;   // tRCD down-counter
    reg [7:0] tras_cnt;   // tRAS down-counter (runs from ACT)
    reg [7:0] trp_cnt;    // tRP  down-counter

    // tras_ok is combinational: asserted when tras_cnt has reached zero
    assign tras_ok = (tras_cnt == 8'd0);

    // ---------------------------------------------------------------
    // Sequential FSM
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            trcd_cnt <= 8'd0;
            tras_cnt <= 8'd0;
            trp_cnt  <= 8'd0;
            open_row <= {ROW_ADDR_W{1'b0}};
        end else begin
            case (state)

                // ---- IDLE: precharged, waiting for ACTIVATE --------
                S_IDLE: begin
                    if (cmd_valid && cmd_in == CMD_ACT) begin
                        open_row <= row_addr_in;
                        trcd_cnt <= INIT_TRCD;
                        tras_cnt <= INIT_TRAS;
                        state    <= S_ACTIVATING;
                    end
                end

                // ---- ACTIVATING: tRCD and tRAS both counting -------
                S_ACTIVATING: begin
                    // tRAS timer continues to run
                    if (tras_cnt != 8'd0) tras_cnt <= tras_cnt - 8'd1;

                    // tRCD timer controls exit to ACTIVE
                    if (trcd_cnt == 8'd0) begin
                        state <= S_ACTIVE;
                    end else begin
                        trcd_cnt <= trcd_cnt - 8'd1;
                    end
                end

                // ---- ACTIVE: row open; RD/WR accepted --------------
                S_ACTIVE: begin
                    // tRAS timer continues until satisfied
                    if (tras_cnt != 8'd0) tras_cnt <= tras_cnt - 8'd1;

                    // PRE only accepted when tRAS constraint is met
                    if (cmd_valid && cmd_in == CMD_PRE && tras_ok) begin
                        trp_cnt <= INIT_TRP;
                        state   <= S_PRECHARGING;
                    end
                end

                // ---- PRECHARGING: waiting tRP before returning -----
                S_PRECHARGING: begin
                    if (trp_cnt == 8'd0) begin
                        state <= S_IDLE;
                    end else begin
                        trp_cnt <= trp_cnt - 8'd1;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // ---------------------------------------------------------------
    // Combinational output logic
    // ---------------------------------------------------------------
    always @(*) begin
        case (state)
            S_IDLE:        begin fsm_ready = 1'b1; row_active = 1'b0; end
            S_ACTIVATING:  begin fsm_ready = 1'b0; row_active = 1'b0; end
            S_ACTIVE:      begin fsm_ready = 1'b1; row_active = 1'b1; end
            S_PRECHARGING: begin fsm_ready = 1'b0; row_active = 1'b0; end
            default:       begin fsm_ready = 1'b0; row_active = 1'b0; end
        endcase
        state_out = state;
    end

endmodule

`default_nettype wire
