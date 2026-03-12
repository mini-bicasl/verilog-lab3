// timing_ctrl.v – JEDEC DDR4 timing constraint enforcer
//
// Tracks countdown counters for every inter-command timing constraint and
// presents tc_ok=1 when all applicable constraints are satisfied for the
// proposed command (tc_cmd, tc_bank_group, tc_bank).
//
// Constraints enforced (all timing values are cycle-count parameters):
//   tRCD   – ACT → RD/WR,          per bank
//   tRP    – PRE → ACT,            per bank
//   tRAS   – ACT → earliest PRE,   per bank
//   tRC    – ACT → ACT same bank (= tRAS + tRP), per bank
//   tRRD_S – ACT → ACT different bank group, global
//   tRRD_L – ACT → ACT same bank group,      per bank group
//   tCCD_S – CAS → CAS different bank group, global
//   tCCD_L – CAS → CAS same bank group,      per bank group
//   tFAW   – four-activate window (4 global slots)
//   tWTR_S – WR  → RD  different bank group, global
//   tWTR_L – WR  → RD  same bank group,      per bank group
//   tRTP   – RD  → PRE,            per bank
//   tWR    – WR  → PRE,            per bank
//
// Interface (docs/ARCHITECTURE.md §3.3):
//   tc_cmd        [2:0] – proposed command (NOP/ACT/RD/WR/PRE/REF)
//   tc_bank_group [1:0] – bank group of proposed command
//   tc_bank       [1:0] – bank of proposed command
//   tc_ok               – 1 = all constraints satisfied; command may issue
//
// When tc_ok=1 the command is issued this clock cycle.  On the following
// rising edge all affected counters are (re)loaded.  All counters count down
// to 0; 0 means the constraint is satisfied.  A counter loaded with (P – 1)
// reaches 0 exactly P clock cycles after the issuing command, matching the
// JEDEC "minimum P-cycle gap" semantics.
//
// Reset: active-low, synchronous on posedge clk; also reacts asynchronously
// to negedge rst_n (consistent with bank_fsm.v).
//
// Compile & run:
//   iverilog -g2012 -o build/timing_ctrl.out tb/timing_ctrl_tb.v rtl/timing_ctrl.v
//   vvp build/timing_ctrl.out

`default_nettype none

module timing_ctrl #(
    parameter BANK_GROUPS     = 4,
    parameter BANKS_PER_GROUP = 4,
    // All timing parameters are in clock cycles (DDR4-3200 defaults)
    parameter P_TRCD   = 14,   // ACT → RD/WR
    parameter P_TRP    = 14,   // PRE → ACT
    parameter P_TRAS   = 52,   // ACT → earliest PRE
    parameter P_TRC    = 66,   // ACT → ACT same bank (= tRAS + tRP)
    parameter P_TRRD_S = 4,    // ACT → ACT different bank group
    parameter P_TRRD_L = 6,    // ACT → ACT same bank group
    parameter P_TCCD_S = 4,    // CAS → CAS different bank group
    parameter P_TCCD_L = 6,    // CAS → CAS same bank group
    parameter P_TFAW   = 40,   // Four-activate window (cycle count)
    parameter P_TWTR_S = 4,    // WR  → RD  different bank group
    parameter P_TWTR_L = 12,   // WR  → RD  same bank group
    parameter P_TRTP   = 12,   // RD  → PRE
    parameter P_TWR    = 24    // WR  → PRE (write recovery)
)(
    input  wire       clk,
    input  wire       rst_n,

    // Proposed command from cmd_scheduler
    input  wire [2:0] tc_cmd,
    input  wire [1:0] tc_bank_group,
    input  wire [1:0] tc_bank,

    // 1 = all timing constraints satisfied; command may issue this cycle
    output wire       tc_ok
);

    // ---------------------------------------------------------------
    // Command encodings (match cmd_scheduler / bank_fsm convention)
    // ---------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    // CMD_REF = 3'd5 handled by default (always ok)

    // ---------------------------------------------------------------
    // Flat bank index: {bank_group[1:0], bank[1:0]} → 0..15
    // ---------------------------------------------------------------
    localparam TOTAL_BANKS = BANK_GROUPS * BANKS_PER_GROUP; // 16

    wire [3:0] bidx;
    assign bidx = {tc_bank_group, tc_bank};

    // ---------------------------------------------------------------
    // Counters (8-bit; 0 = constraint satisfied, counts down to 0)
    // ---------------------------------------------------------------

    // --- Global (cross-bank-group) ---
    reg [7:0] trrd_s_cnt;       // tRRD_S: last ACT  → next ACT  (any BG)
    reg [7:0] tccd_s_cnt;       // tCCD_S: last CAS  → next CAS  (any BG)
    reg [7:0] twtr_s_cnt;       // tWTR_S: last WR   → next RD   (any BG)

    // --- Per bank group (indices 0..3) ---
    reg [7:0] trrd_l_cnt [0:3]; // tRRD_L: same-BG ACT → ACT
    reg [7:0] tccd_l_cnt [0:3]; // tCCD_L: same-BG CAS → CAS
    reg [7:0] twtr_l_cnt [0:3]; // tWTR_L: same-BG WR  → RD

    // --- Per bank (indices 0..15 = {BG,Bank}) ---
    reg [7:0] trcd_cnt [0:15];  // tRCD: ACT → RD/WR
    reg [7:0] tras_cnt [0:15];  // tRAS: ACT → PRE
    reg [7:0] trp_cnt  [0:15];  // tRP:  PRE → ACT
    reg [7:0] trc_cnt  [0:15];  // tRC:  ACT → ACT same bank
    reg [7:0] trtp_cnt [0:15];  // tRTP: RD  → PRE
    reg [7:0] twr_cnt  [0:15];  // tWR:  WR  → PRE

    // --- tFAW: four slots tracking the last four ACTs ---
    reg [7:0] faw_cnt  [0:3];

    // ---------------------------------------------------------------
    // tc_ok – purely combinational via continuous assignments.
    //
    // Using continuous assign (not always @(*) + reg) ensures tc_ok
    // updates in the same delta cycle as any input change, avoiding
    // simulator-dependent active-event scheduling artefacts.
    // ---------------------------------------------------------------

    // Extract per-bank and per-BG counters indexed by the proposed cmd
    wire [7:0] tc_trp    = trp_cnt [bidx];
    wire [7:0] tc_tras   = tras_cnt[bidx];
    wire [7:0] tc_trc    = trc_cnt [bidx];
    wire [7:0] tc_trcd   = trcd_cnt[bidx];
    wire [7:0] tc_trtp   = trtp_cnt[bidx];
    wire [7:0] tc_twr    = twr_cnt [bidx];
    wire [7:0] tc_trrd_l = trrd_l_cnt[tc_bank_group];
    wire [7:0] tc_tccd_l = tccd_l_cnt[tc_bank_group];
    wire [7:0] tc_twtr_l = twtr_l_cnt[tc_bank_group];

    // tFAW: at least one slot must be free (= 0) to allow a new ACT
    wire faw_ok = (faw_cnt[0] == 8'd0) | (faw_cnt[1] == 8'd0)
                | (faw_cnt[2] == 8'd0) | (faw_cnt[3] == 8'd0);

    // Per-command gate expressions
    wire ok_act = (trrd_s_cnt == 8'd0) & (tc_trrd_l == 8'd0) & faw_ok
                & (tc_trp == 8'd0) & (tc_trc == 8'd0);

    wire ok_rd  = (tccd_s_cnt == 8'd0) & (tc_tccd_l == 8'd0)
                & (twtr_s_cnt == 8'd0) & (tc_twtr_l == 8'd0)
                & (tc_trcd == 8'd0);

    wire ok_wr  = (tccd_s_cnt == 8'd0) & (tc_tccd_l == 8'd0)
                & (tc_trcd == 8'd0);

    wire ok_pre = (tc_tras == 8'd0) & (tc_trtp == 8'd0) & (tc_twr == 8'd0);

    // Final mux: NOP and REF are always OK
    assign tc_ok = (tc_cmd == CMD_ACT) ? ok_act :
                   (tc_cmd == CMD_RD)  ? ok_rd  :
                   (tc_cmd == CMD_WR)  ? ok_wr  :
                   (tc_cmd == CMD_PRE) ? ok_pre : 1'b1;

    // ---------------------------------------------------------------
    // Command-issued flags (combinational; used in sequential block)
    // ---------------------------------------------------------------
    wire is_act = tc_ok & (tc_cmd == CMD_ACT);
    wire is_rd  = tc_ok & (tc_cmd == CMD_RD);
    wire is_wr  = tc_ok & (tc_cmd == CMD_WR);
    wire is_pre = tc_ok & (tc_cmd == CMD_PRE);
    wire is_cas = is_rd | is_wr;

    // tFAW slot selection: load the lowest-indexed slot that is free (= 0).
    // tc_ok for ACT already guarantees at least one slot is free, so
    // exactly one of these will be asserted on any ACT.
    wire faw0_free = (faw_cnt[0] == 8'd0);
    wire faw1_free = (faw_cnt[1] == 8'd0);
    wire faw2_free = (faw_cnt[2] == 8'd0);

    wire load_faw0 = is_act &  faw0_free;
    wire load_faw1 = is_act & ~faw0_free &  faw1_free;
    wire load_faw2 = is_act & ~faw0_free & ~faw1_free &  faw2_free;
    wire load_faw3 = is_act & ~faw0_free & ~faw1_free & ~faw2_free;

    // ---------------------------------------------------------------
    // Sequential: counter update (active-low async reset)
    // ---------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trrd_s_cnt <= 8'd0;
            tccd_s_cnt <= 8'd0;
            twtr_s_cnt <= 8'd0;
            faw_cnt[0] <= 8'd0; faw_cnt[1] <= 8'd0;
            faw_cnt[2] <= 8'd0; faw_cnt[3] <= 8'd0;
            for (i = 0; i < 4; i = i + 1) begin
                trrd_l_cnt[i] <= 8'd0;
                tccd_l_cnt[i] <= 8'd0;
                twtr_l_cnt[i] <= 8'd0;
            end
            for (i = 0; i < 16; i = i + 1) begin
                trcd_cnt[i] <= 8'd0;
                tras_cnt[i] <= 8'd0;
                trp_cnt[i]  <= 8'd0;
                trc_cnt[i]  <= 8'd0;
                trtp_cnt[i] <= 8'd0;
                twr_cnt[i]  <= 8'd0;
            end
        end else begin
            // ---- Global counters ----
            // Load takes priority over decrement; saturate at 0.
            trrd_s_cnt <= is_act ? (P_TRRD_S - 1)
                        : (trrd_s_cnt != 0 ? trrd_s_cnt - 8'd1 : 8'd0);

            tccd_s_cnt <= is_cas ? (P_TCCD_S - 1)
                        : (tccd_s_cnt != 0 ? tccd_s_cnt - 8'd1 : 8'd0);

            twtr_s_cnt <= is_wr  ? (P_TWTR_S - 1)
                        : (twtr_s_cnt != 0 ? twtr_s_cnt - 8'd1 : 8'd0);

            // ---- Per-BG counters ----
            for (i = 0; i < 4; i = i + 1) begin
                trrd_l_cnt[i] <= (is_act && tc_bank_group == i[1:0])
                               ? (P_TRRD_L - 1)
                               : (trrd_l_cnt[i] != 0 ? trrd_l_cnt[i] - 8'd1 : 8'd0);

                tccd_l_cnt[i] <= (is_cas && tc_bank_group == i[1:0])
                               ? (P_TCCD_L - 1)
                               : (tccd_l_cnt[i] != 0 ? tccd_l_cnt[i] - 8'd1 : 8'd0);

                twtr_l_cnt[i] <= (is_wr  && tc_bank_group == i[1:0])
                               ? (P_TWTR_L - 1)
                               : (twtr_l_cnt[i] != 0 ? twtr_l_cnt[i] - 8'd1 : 8'd0);
            end

            // ---- Per-bank counters ----
            for (i = 0; i < 16; i = i + 1) begin
                trcd_cnt[i] <= (is_act && bidx == i[3:0])
                             ? (P_TRCD - 1)
                             : (trcd_cnt[i] != 0 ? trcd_cnt[i] - 8'd1 : 8'd0);

                tras_cnt[i] <= (is_act && bidx == i[3:0])
                             ? (P_TRAS - 1)
                             : (tras_cnt[i] != 0 ? tras_cnt[i] - 8'd1 : 8'd0);

                trp_cnt[i]  <= (is_pre && bidx == i[3:0])
                             ? (P_TRP - 1)
                             : (trp_cnt[i]  != 0 ? trp_cnt[i]  - 8'd1 : 8'd0);

                trc_cnt[i]  <= (is_act && bidx == i[3:0])
                             ? (P_TRC - 1)
                             : (trc_cnt[i]  != 0 ? trc_cnt[i]  - 8'd1 : 8'd0);

                trtp_cnt[i] <= (is_rd  && bidx == i[3:0])
                             ? (P_TRTP - 1)
                             : (trtp_cnt[i] != 0 ? trtp_cnt[i] - 8'd1 : 8'd0);

                twr_cnt[i]  <= (is_wr  && bidx == i[3:0])
                             ? (P_TWR - 1)
                             : (twr_cnt[i]  != 0 ? twr_cnt[i]  - 8'd1 : 8'd0);
            end

            // ---- tFAW slots ----
            faw_cnt[0] <= load_faw0 ? (P_TFAW - 1)
                        : (faw_cnt[0] != 0 ? faw_cnt[0] - 8'd1 : 8'd0);

            faw_cnt[1] <= load_faw1 ? (P_TFAW - 1)
                        : (faw_cnt[1] != 0 ? faw_cnt[1] - 8'd1 : 8'd0);

            faw_cnt[2] <= load_faw2 ? (P_TFAW - 1)
                        : (faw_cnt[2] != 0 ? faw_cnt[2] - 8'd1 : 8'd0);

            faw_cnt[3] <= load_faw3 ? (P_TFAW - 1)
                        : (faw_cnt[3] != 0 ? faw_cnt[3] - 8'd1 : 8'd0);
        end
    end

endmodule

`default_nettype wire
