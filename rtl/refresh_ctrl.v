// refresh_ctrl.v – DDR4 Refresh Controller
//
// Implements the three-state refresh FSM from docs/ARCHITECTURE.md §6.2:
//   NORMAL -> REF_PENDING -> REFRESHING -> NORMAL
//
// Supports two refresh modes (selected by rfsh_mode):
//   0 = All-Bank Refresh (REFab): one REF to all banks every tREFI.
//       All banks must be idle before the REF issues; all stall for tRFC.
//   1 = Per-Bank Refresh (REFpb): one bank refreshed per tREFI interval,
//       cycling through all BANK_GROUPS × BANKS_PER_GROUP banks in order.
//       Other banks may remain active while the target bank refreshes.
//
// Temperature-compensated refresh: temp_throttle=1 halves the effective
// tREFI (per JEDEC DDR4 >85 °C requirement).
//
// Interface outputs:
//   ref_req       – asserted in REF_PENDING; arbiter should stop new ACTs
//   ref_issue     – single-cycle pulse when REF command should be issued
//   ref_stall     – asserted during REFRESHING (tRFC countdown active)
//   ref_bank      – target bank  for REFpb (valid when rfsh_mode=1)
//   ref_bank_group– target group for REFpb (valid when rfsh_mode=1)
//   ref_active    – 1 whenever not in NORMAL (refresh cycle in progress)
//
// Interface inputs:
//   all_banks_idle – from bank FSMs: all banks are precharged
//   rfsh_mode      – 0=REFab, 1=REFpb
//   temp_throttle  – 1=high temperature, halve tREFI
//
// Reset: active-low synchronous (posedge clk).
//
// Compile & run:
//   iverilog -g2012 -o build/refresh_ctrl.out tb/refresh_ctrl_tb.v rtl/refresh_ctrl.v
//   vvp build/refresh_ctrl.out

`default_nettype none

module refresh_ctrl #(
    parameter BANK_GROUPS      = 4,
    parameter BANKS_PER_GROUP  = 4,
    // Timing parameters in clock cycles (DDR4-3200, 625 ps tCK defaults)
    parameter P_TREFI          = 12480, // tREFI  7800 ns / 0.625 ns
    parameter P_TRFC           = 560    // tRFC1  350 ns  / 0.625 ns (8 Gb)
)(
    input  wire clk,
    input  wire rst_n,

    // Scheduler / bank interface
    input  wire all_banks_idle, // all banks are in IDLE (precharged)
    input  wire rfsh_mode,      // 0 = REFab, 1 = REFpb
    input  wire temp_throttle,  // 1 = >85 °C; halve tREFI

    // Outputs to arbiter / command bus
    output reg  ref_req,        // 1 while waiting for banks to drain
    output reg  ref_issue,      // 1-cycle pulse: issue REF to DRAM now
    output reg  ref_stall,      // 1 during tRFC countdown (block all cmds)
    output reg  ref_active,     // 1 whenever not in NORMAL

    // REFpb target (valid when rfsh_mode=1 and ref_issue=1)
    output reg  [1:0] ref_bank_group,
    output reg  [1:0] ref_bank
);

    // ---------------------------------------------------------------
    // Derived constants
    // ---------------------------------------------------------------
    localparam TOTAL_BANKS = BANK_GROUPS * BANKS_PER_GROUP;

    // Counter widths – sized to hold worst-case values
    localparam TREFI_W = 14;  // 2^14 = 16384 > 12480
    localparam TRFC_W  = 10;  // 2^10 = 1024  > 560
    localparam BANK_W  = 4;   // up to 16 banks total

    // ---------------------------------------------------------------
    // State encodings
    // ---------------------------------------------------------------
    localparam S_NORMAL      = 2'd0;
    localparam S_REF_PENDING = 2'd1;
    localparam S_REFRESHING  = 2'd2;

    // ---------------------------------------------------------------
    // Registers
    // ---------------------------------------------------------------
    reg [1:0]        state;
    reg [TREFI_W-1:0] trefi_cnt;   // counts down from P_TREFI-1 to 0
    reg [TRFC_W-1:0]  trfc_cnt;    // counts down during REFRESHING
    reg [BANK_W-1:0]  bank_idx;    // current bank index for REFpb

    // Effective tREFI: halved when temp_throttle is asserted
    wire [TREFI_W-1:0] trefi_val;
    assign trefi_val = temp_throttle ?
                       ((P_TREFI >> 1) - 1) :
                       (P_TREFI - 1);

    // ---------------------------------------------------------------
    // Condition to start a refresh (bank must be idle for REFpb target
    // or all banks must be idle for REFab)
    // ---------------------------------------------------------------
    // For REFab: all_banks_idle must be high.
    // For REFpb: only the target bank needs to be idle; since we do not
    //            have per-bank idle signals in this standalone module we
    //            use all_banks_idle as a conservative approximation
    //            (integrator can replace this with a per-bank signal).
    wire can_refresh;
    assign can_refresh = all_banks_idle;

    // Separate bank index bits: group = idx / BANKS_PER_GROUP,
    //                            bank  = idx % BANKS_PER_GROUP
    // Uses integer division – valid because BANKS_PER_GROUP is a power of 2.
    wire [1:0] bank_idx_group;
    wire [1:0] bank_idx_bank;
    assign bank_idx_group = bank_idx / BANKS_PER_GROUP;
    assign bank_idx_bank  = bank_idx % BANKS_PER_GROUP;

    // ---------------------------------------------------------------
    // Sequential FSM
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_NORMAL;
            trefi_cnt      <= P_TREFI - 1;
            trfc_cnt       <= {TRFC_W{1'b0}};
            bank_idx       <= {BANK_W{1'b0}};
            ref_req        <= 1'b0;
            ref_issue      <= 1'b0;
            ref_stall      <= 1'b0;
            ref_active     <= 1'b0;
            ref_bank_group <= 2'd0;
            ref_bank       <= 2'd0;
        end else begin
            // Default: clear single-cycle pulse
            ref_issue <= 1'b0;

            case (state)

                // ---- NORMAL: counting down tREFI --------------------
                S_NORMAL: begin
                    ref_req    <= 1'b0;
                    ref_stall  <= 1'b0;
                    ref_active <= 1'b0;

                    if (trefi_cnt == {TREFI_W{1'b0}}) begin
                        // Interval expired → move to REF_PENDING
                        trefi_cnt <= trefi_val;
                        state     <= S_REF_PENDING;
                        ref_req   <= 1'b1;
                        ref_active<= 1'b1;
                    end else begin
                        // Clamp counter if temp_throttle asserts mid-interval
                        // so the throttled tREFI takes effect immediately.
                        if (trefi_cnt > trefi_val)
                            trefi_cnt <= trefi_val;
                        else
                            trefi_cnt <= trefi_cnt - {{(TREFI_W-1){1'b0}}, 1'b1};
                    end
                end

                // ---- REF_PENDING: wait for banks to drain -----------
                S_REF_PENDING: begin
                    ref_req    <= 1'b1;
                    ref_active <= 1'b1;

                    if (can_refresh) begin
                        // Snapshot REFpb target before issuing
                        if (rfsh_mode) begin
                            ref_bank_group <= bank_idx_group;
                            ref_bank       <= bank_idx_bank;
                        end else begin
                            ref_bank_group <= 2'd0;
                            ref_bank       <= 2'd0;
                        end

                        ref_issue <= 1'b1;
                        ref_stall <= 1'b1;
                        ref_req   <= 1'b0;
                        state     <= S_REFRESHING;
                        trfc_cnt  <= P_TRFC - 1;
                    end
                end

                // ---- REFRESHING: tRFC countdown ---------------------
                S_REFRESHING: begin
                    ref_stall  <= 1'b1;
                    ref_active <= 1'b1;

                    if (trfc_cnt == {TRFC_W{1'b0}}) begin
                        // tRFC done; advance bank index for REFpb
                        if (rfsh_mode) begin
                            if (bank_idx == (TOTAL_BANKS - 1))
                                bank_idx <= {BANK_W{1'b0}};
                            else
                                bank_idx <= bank_idx + {{(BANK_W-1){1'b0}}, 1'b1};
                        end
                        ref_stall  <= 1'b0;
                        ref_active <= 1'b0;
                        state      <= S_NORMAL;
                    end else begin
                        trfc_cnt <= trfc_cnt - {{(TRFC_W-1){1'b0}}, 1'b1};
                    end
                end

                default: state <= S_NORMAL;

            endcase
        end
    end

endmodule

`default_nettype wire
