// cmd_scheduler.v – DDR4 Command Scheduler
//
// Translates arbitrated host requests (from cmd_arbiter) into the correct
// DRAM command sequences: ACTIVATE, READ/WRITE, and PRECHARGE.
//
// Open-row policy:
//   - Open-row HIT  : if the target bank already has the requested row open,
//                     the scheduler issues READ or WRITE directly (no ACT).
//   - Open-row MISS : if the target bank is idle (precharged), the scheduler
//                     issues ACTIVATE then READ/WRITE.
//   - Row CONFLICT  : if a different row is open in the target bank, the
//                     scheduler issues PRECHARGE → ACTIVATE → READ/WRITE.
//
// Refresh handling:
//   - ref_req (from refresh_ctrl) is forwarded to the upstream arbiter via
//     arb_ready deassertion (arbiter is also connected to ref_req directly).
//   - ref_issue (single-cycle pulse from refresh_ctrl) causes a REF command
//     to be issued on the DRAM bus; all bank open-row state is cleared
//     (conservative all-bank refresh treatment).
//
// Timing interface (docs/ARCHITECTURE.md §3.3):
//   tc_cmd, tc_bank_group, tc_bank → proposed command to timing_ctrl
//   tc_ok                          ← timing_ctrl gates command issuance
//   When tc_ok = 1 the proposed command is issued; timing_ctrl reloads its
//   counters on the following posedge.  For CMD_NOP and CMD_REF tc_ok is
//   always 1 (per timing_ctrl.v implementation).
//
// DRAM command bus outputs:
//   dram_valid      – 1 when a command is issued this cycle
//   dram_cmd        – command issued (same encoding as tc_cmd)
//   dram_bank_group – target bank group
//   dram_bank       – target bank
//   dram_row_addr   – row address (valid when dram_cmd = ACT)
//   dram_col_addr   – column address (valid when dram_cmd = RD or WR)
//
// Address decode (from docs/ARCHITECTURE.md §7):
//   addr[32:22] → row   (11 bits, zero-padded to ROW_ADDR_W)
//   addr[21:20] → bank group
//   addr[19:18] → bank
//   addr[17:8]  → column (10 bits, truncated/padded to COL_ADDR_W)
//
// Reset: active-low asynchronous (negedge rst_n in sensitivity list).
//
// Compile & run:
//   iverilog -g2012 -o build/cmd_scheduler.out tb/cmd_scheduler_tb.v rtl/cmd_scheduler.v
//   vvp build/cmd_scheduler.out

`default_nettype none

module cmd_scheduler #(
    parameter AXI_ADDR_W      = 34,
    parameter AXI_ID_W        = 8,
    parameter BANK_GROUPS     = 4,
    parameter BANKS_PER_GROUP = 4,
    parameter ROW_ADDR_W      = 17,
    parameter COL_ADDR_W      = 10
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Arbitrated request from cmd_arbiter
    input  wire                   arb_valid,
    output wire                   arb_ready,
    input  wire                   arb_is_write,
    input  wire [AXI_ADDR_W-1:0]  arb_addr,

    // Refresh interface (from refresh_ctrl)
    input  wire                   ref_req,    // 1 = arbiter should stop new cmds
    input  wire                   ref_issue,  // 1-cycle pulse: issue REF now

    // Timing controller interface (docs/ARCHITECTURE.md §3.3)
    output wire [2:0]             tc_cmd,
    output wire [1:0]             tc_bank_group,
    output wire [1:0]             tc_bank,
    input  wire                   tc_ok,      // 1 = command may issue this cycle

    // DRAM command bus output
    output wire [2:0]             dram_cmd,
    output wire [1:0]             dram_bank_group,
    output wire [1:0]             dram_bank,
    output wire [ROW_ADDR_W-1:0]  dram_row_addr,
    output wire [COL_ADDR_W-1:0]  dram_col_addr,
    output wire                   dram_valid
);

    // ---------------------------------------------------------------
    // Command encodings (match bank_fsm / timing_ctrl convention)
    // ---------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // ---------------------------------------------------------------
    // FSM state encodings
    // ---------------------------------------------------------------
    localparam S_IDLE = 3'd0;  // ready to accept from arbiter / handle REF
    localparam S_PRE  = 3'd1;  // proposing PRECHARGE to timing_ctrl
    localparam S_ACT  = 3'd2;  // proposing ACTIVATE  to timing_ctrl
    localparam S_DATA = 3'd3;  // proposing RD or WR  to timing_ctrl

    reg [2:0] state;

    // ---------------------------------------------------------------
    // Pending command registers (latched from arbiter in S_IDLE)
    // ---------------------------------------------------------------
    reg [1:0]            pend_bg;
    reg [1:0]            pend_bank;
    reg [ROW_ADDR_W-1:0] pend_row;
    reg [COL_ADDR_W-1:0] pend_col;
    reg                  pend_is_write;

    // Flat 4-bit bank index for the pending command
    wire [3:0] pend_bidx = {pend_bg, pend_bank};

    // ---------------------------------------------------------------
    // Internal bank state (mirrors bank_fsm behaviour)
    //   row_open[i]     – 1 if bank i has an open row
    //   open_row_mem[i] – the open row address for bank i
    //
    // The flat bank index uses the 4-bit concatenation {bg[1:0], bank[1:0]},
    // matching timing_ctrl.v.  This gives 16 unique slots regardless of the
    // BANK_GROUPS / BANKS_PER_GROUP parameters, so TOTAL_BANKS is fixed at 16.
    // ---------------------------------------------------------------
    localparam TOTAL_BANKS = 16;  // full 4-bit address space: {bg[1:0], bank[1:0]}

    reg [TOTAL_BANKS-1:0] row_open;
    reg [ROW_ADDR_W-1:0]  open_row_mem [0:TOTAL_BANKS-1];

    // ---------------------------------------------------------------
    // Address decode (combinational from arb_addr)
    // Fixed bit positions per docs/ARCHITECTURE.md §7.
    // Assumes AXI_ADDR_W = 34, ROW_ADDR_W >= 11, COL_ADDR_W = 10.
    // ---------------------------------------------------------------
    wire [1:0]            dec_bg   = arb_addr[21:20];
    wire [1:0]            dec_bank = arb_addr[19:18];
    wire [10:0]           dec_row_raw = arb_addr[32:22];
    wire [ROW_ADDR_W-1:0] dec_row  = {{(ROW_ADDR_W-11){1'b0}}, dec_row_raw};
    wire [COL_ADDR_W-1:0] dec_col  = arb_addr[COL_ADDR_W+7:8];
    wire [3:0]            dec_bidx = {dec_bg, dec_bank};

    // ---------------------------------------------------------------
    // Combinational outputs
    // ---------------------------------------------------------------

    // arb_ready: accept a new request only when idle, no REF is issuing,
    // and no refresh request is pending (prevents protocol violations).
    assign arb_ready = (state == S_IDLE) && !ref_issue && !ref_req;

    // tc_cmd: proposed command to timing_ctrl based on current FSM state
    assign tc_cmd =
        (state == S_IDLE && ref_issue)                    ? CMD_REF :
        (state == S_PRE)                                  ? CMD_PRE :
        (state == S_ACT)                                  ? CMD_ACT :
        (state == S_DATA && pend_is_write)                ? CMD_WR  :
        (state == S_DATA)                                 ? CMD_RD  :
                                                            CMD_NOP;

    // tc_bank_group / tc_bank: target bank for the proposed command
    assign tc_bank_group = (state == S_IDLE) ? 2'b0 : pend_bg;
    assign tc_bank       = (state == S_IDLE) ? 2'b0 : pend_bank;

    // Command is issued this cycle when tc_ok=1 and we have a real command
    wire cmd_issue = tc_ok && (tc_cmd != CMD_NOP);

    // DRAM command bus (valid only when a command actually issues)
    assign dram_valid      = cmd_issue;
    assign dram_cmd        = tc_cmd;
    assign dram_bank_group = tc_bank_group;
    assign dram_bank       = tc_bank;
    assign dram_row_addr   = (state == S_ACT) ? pend_row : {ROW_ADDR_W{1'b0}};
    assign dram_col_addr   = (state == S_DATA) ? pend_col : {COL_ADDR_W{1'b0}};

    // ---------------------------------------------------------------
    // Sequential FSM (active-low async reset)
    // ---------------------------------------------------------------
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            pend_bg       <= 2'b0;
            pend_bank     <= 2'b0;
            pend_row      <= {ROW_ADDR_W{1'b0}};
            pend_col      <= {COL_ADDR_W{1'b0}};
            pend_is_write <= 1'b0;
            row_open      <= {TOTAL_BANKS{1'b0}};
            for (k = 0; k < TOTAL_BANKS; k = k + 1)
                open_row_mem[k] <= {ROW_ADDR_W{1'b0}};
        end else begin
            case (state)

                // ---------------------------------------------------
                // IDLE: handle REF pulse, or accept a new request.
                // ---------------------------------------------------
                S_IDLE: begin
                    if (ref_issue) begin
                        // REF command issued this cycle (tc_ok always 1 for REF).
                        // Clear all open-row state (all-bank refresh treatment).
                        row_open <= {TOTAL_BANKS{1'b0}};
                    end else if (arb_valid && !ref_req) begin
                        // Latch the incoming request and decode its address.
                        pend_bg       <= dec_bg;
                        pend_bank     <= dec_bank;
                        pend_row      <= dec_row;
                        pend_col      <= dec_col;
                        pend_is_write <= arb_is_write;

                        // Choose the command sequence based on bank state:
                        if (!row_open[dec_bidx]) begin
                            // Bank is idle – need ACTIVATE first
                            state <= S_ACT;
                        end else if (open_row_mem[dec_bidx] == dec_row) begin
                            // Same row is already open – direct READ/WRITE
                            state <= S_DATA;
                        end else begin
                            // Different row open – PRECHARGE then ACTIVATE
                            state <= S_PRE;
                        end
                    end
                end

                // ---------------------------------------------------
                // PRE: propose PRECHARGE; wait for timing_ctrl to allow it.
                // ---------------------------------------------------
                S_PRE: begin
                    if (tc_ok) begin
                        // PRECHARGE issued; mark bank as precharged.
                        row_open[pend_bidx] <= 1'b0;
                        state               <= S_ACT;
                    end
                end

                // ---------------------------------------------------
                // ACT: propose ACTIVATE; wait for timing_ctrl to allow it.
                // ---------------------------------------------------
                S_ACT: begin
                    if (tc_ok) begin
                        // ACTIVATE issued; record the newly open row.
                        row_open[pend_bidx]     <= 1'b1;
                        open_row_mem[pend_bidx] <= pend_row;
                        state                   <= S_DATA;
                    end
                end

                // ---------------------------------------------------
                // DATA: propose READ or WRITE; wait for tc_ok.
                // ---------------------------------------------------
                S_DATA: begin
                    if (tc_ok) begin
                        // READ or WRITE issued; return to IDLE.
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
