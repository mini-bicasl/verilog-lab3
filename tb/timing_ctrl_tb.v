// timing_ctrl_tb.v – Testbench for timing_ctrl (DDR4 timing constraint enforcer)
//
// Uses compact timing parameters chosen so that:
//   - every binding constraint is uniquely identifiable (L-variant > S-variant)
//   - tRC (13) > tFAW (12) so tRC is binding for same-bank ACT-to-ACT
//   - 3 * P_TRRD_S (9) < P_TFAW (12) so 4 ACTs complete before the first
//     FAW slot expires
//
// Test plan:
//   T1:  Reset / NOP always OK
//   T2:  tRRD_S  – ACT → ACT different BG blocked P_TRRD_S-1 cycles
//   T3:  tRRD_L  – ACT → ACT same BG     blocked P_TRRD_L-1 cycles
//   T4:  tFAW    – 4th ACT fills all slots; 5th blocked until oldest expires
//   T5:  tCCD_S  – WR  → WR  different BG blocked P_TCCD_S-1 cycles
//   T6:  tCCD_L  – WR  → WR  same BG     blocked P_TCCD_L-1 cycles
//   T7:  tWTR_S  – WR  → RD  different BG blocked P_TWTR_S-1 cycles
//   T8:  tWTR_L  – WR  → RD  same BG     blocked P_TWTR_L-1 cycles
//   T9:  tRCD    – ACT → RD  same bank   blocked P_TRCD-1 cycles
//   T10: tRP     – PRE → ACT same bank   blocked P_TRP-1  cycles
//   T11: tRAS    – ACT → PRE same bank   blocked P_TRAS-1 cycles
//   T12: tRC     – ACT → ACT same bank   blocked P_TRC-1  cycles
//   T13: tRTP    – RD  → PRE same bank   blocked P_TRTP-1 cycles
//   T14: tWR     – WR  → PRE same bank   blocked P_TWR-1  cycles
//
// Compile & run:
//   iverilog -g2012 -o build/timing_ctrl.out tb/timing_ctrl_tb.v rtl/timing_ctrl.v
//   vvp build/timing_ctrl.out

`timescale 1ns/1ps

module timing_ctrl_tb;

    // ----------------------------------------------------------------
    // Compact timing parameters
    // ----------------------------------------------------------------
    localparam P_TRCD   = 4;
    localparam P_TRP    = 5;
    localparam P_TRAS   = 8;
    localparam P_TRC    = 13;  // P_TRAS + P_TRP = 8+5; > P_TFAW = 12
    localparam P_TRRD_S = 3;
    localparam P_TRRD_L = 5;   // > P_TRRD_S
    localparam P_TCCD_S = 3;
    localparam P_TCCD_L = 5;   // > P_TCCD_S
    localparam P_TFAW   = 12;  // 3*P_TRRD_S=9 < 12; P_TRC=13 > 12
    localparam P_TWTR_S = 5;   // > P_TCCD_S = 3
    localparam P_TWTR_L = 7;   // > P_TWTR_S
    localparam P_TRTP   = 4;
    localparam P_TWR    = 6;

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg        clk;
    reg        rst_n;
    reg  [2:0] tc_cmd;
    reg  [1:0] tc_bank_group;
    reg  [1:0] tc_bank;
    wire       tc_ok;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    timing_ctrl #(
        .P_TRCD   (P_TRCD),
        .P_TRP    (P_TRP),
        .P_TRAS   (P_TRAS),
        .P_TRC    (P_TRC),
        .P_TRRD_S (P_TRRD_S),
        .P_TRRD_L (P_TRRD_L),
        .P_TCCD_S (P_TCCD_S),
        .P_TCCD_L (P_TCCD_L),
        .P_TFAW   (P_TFAW),
        .P_TWTR_S (P_TWTR_S),
        .P_TWTR_L (P_TWTR_L),
        .P_TRTP   (P_TRTP),
        .P_TWR    (P_TWR)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .tc_cmd       (tc_cmd),
        .tc_bank_group(tc_bank_group),
        .tc_bank      (tc_bank),
        .tc_ok        (tc_ok)
    );

    // ----------------------------------------------------------------
    // Command encodings
    // ----------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;

    // ----------------------------------------------------------------
    // Clock generation – 10 ns period
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // VCD waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-timing/timing_ctrl.vcd");
        $dumpvars(0, timing_ctrl_tb);
    end

    // ----------------------------------------------------------------
    // Pass / fail tracking
    // ----------------------------------------------------------------
    integer pass_count, fail_count;

    task chk;
        input        cond;
        input [31:0] tid;
        input [159:0] msg;
        begin
            if (cond) begin
                $display("PASS T%0d: %s", tid, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL T%0d: %s  (cmd=%0d bg=%0d bk=%0d ok=%b)",
                         tid, msg, tc_cmd, tc_bank_group, tc_bank, tc_ok);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // do_nop: issue NOP and advance one clock cycle.
    // Starts from anywhere; ends at #1 after next posedge.
    // ----------------------------------------------------------------
    task do_nop;
        begin
            @(negedge clk);
            tc_cmd        = CMD_NOP;
            tc_bank_group = 2'b00;
            tc_bank       = 2'b00;
            @(posedge clk); #1;
        end
    endtask

    // ----------------------------------------------------------------
    // drain(n): advance n NOP cycles to let all counters expire.
    // ----------------------------------------------------------------
    task drain;
        input integer n;
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) do_nop;
        end
    endtask

    // ----------------------------------------------------------------
    // count_wait: count posedge cycles until tc_ok=1.
    // Called AFTER the trigger command is issued and the constrained
    // command has already been placed on tc_cmd/bg/bank inputs.
    // Returns the number of additional posedge cycles waited.
    // Ends at #1 after the posedge where tc_ok became 1.
    // ----------------------------------------------------------------
    task count_wait;
        output integer cnt;
        begin
            cnt = 0;
            while (!tc_ok && cnt < 256) begin
                @(posedge clk); #1;
                cnt = cnt + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Main stimulus
    // ----------------------------------------------------------------
    integer wait_cnt;

    initial begin
        pass_count    = 0;
        fail_count    = 0;
        tc_cmd        = CMD_NOP;
        tc_bank_group = 2'b00;
        tc_bank       = 2'b00;

        // ===========================================================
        // T1: Reset – NOP always OK; ACT/RD/WR/PRE also OK (all
        //     counters initialised to 0 after reset).
        // ===========================================================
        rst_n = 1'b0;
        repeat(4) @(posedge clk); #1;
        chk(tc_ok == 1'b1, 1, "NOP ok while in reset");

        @(negedge clk); tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b00;
        @(posedge clk); #1;
        chk(tc_ok == 1'b1, 1, "ACT ok: all counters 0 after reset");

        rst_n = 1'b1;
        @(negedge clk); tc_cmd = CMD_NOP;
        @(posedge clk); #1;
        // Wait for the rst_n-release ACT's counters to drain before tests
        drain(20);

        // ===========================================================
        // T2: tRRD_S – ACT to ACT, different bank group
        //     Expected wait = P_TRRD_S - 1 = 2 cycles
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b00;
        chk(tc_ok == 1'b1, 2, "tRRD_S: trigger ACT ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b01; tc_bank = 2'b00;
        chk(tc_ok == 1'b0, 2, "tRRD_S: second ACT immediately blocked");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRRD_S - 1, 2, "tRRD_S: blocked for exactly P_TRRD_S-1 cycles");
        chk(tc_ok == 1'b1,            2, "tRRD_S: unblocked after tRRD_S cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T3: tRRD_L – ACT to ACT, same bank group (BG=0, diff bank)
        //     Expected wait = P_TRRD_L - 1 = 4 cycles
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b00;
        chk(tc_ok == 1'b1, 3, "tRRD_L: trigger ACT ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b01;
        chk(tc_ok == 1'b0, 3, "tRRD_L: same-BG ACT immediately blocked");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRRD_L - 1, 3, "tRRD_L: blocked for exactly P_TRRD_L-1 cycles");
        chk(tc_ok == 1'b1,            3, "tRRD_L: unblocked after tRRD_L cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T4: tFAW – four-activate window
        //     Issue 4 ACTs to BG0-3/Bank0 (each waits P_TRRD_S-1).
        //     5th ACT must be blocked until oldest FAW slot expires.
        // ===========================================================
        // ACT1 – BG0/Bank0
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b00;
        chk(tc_ok == 1'b1, 4, "tFAW: ACT1 ok");
        @(posedge clk); #1;

        // ACT2 – BG1/Bank0 (wait for tRRD_S)
        @(negedge clk); tc_cmd = CMD_ACT; tc_bank_group = 2'b01; tc_bank = 2'b00;
        count_wait(wait_cnt); @(posedge clk); #1;

        // ACT3 – BG2/Bank0
        @(negedge clk); tc_cmd = CMD_ACT; tc_bank_group = 2'b10; tc_bank = 2'b00;
        count_wait(wait_cnt); @(posedge clk); #1;

        // ACT4 – BG3/Bank0 (fills the last FAW slot)
        @(negedge clk); tc_cmd = CMD_ACT; tc_bank_group = 2'b11; tc_bank = 2'b00;
        count_wait(wait_cnt); @(posedge clk); #1;

        // 5th ACT – should be blocked immediately (all 4 FAW slots filled)
        @(negedge clk); tc_cmd = CMD_ACT; tc_bank_group = 2'b00; tc_bank = 2'b01;
        chk(tc_ok == 1'b0, 4, "tFAW: 5th ACT blocked (all 4 slots active)");
        count_wait(wait_cnt);
        chk(tc_ok == 1'b1, 4, "tFAW: 5th ACT unblocked after oldest slot expires");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T5: tCCD_S – CAS to CAS, different bank group
        //     WR → WR (different BG); expected wait = P_TCCD_S - 1 = 2
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b00; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 5, "tCCD_S: trigger WR ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b10; tc_bank = 2'b10;
        chk(tc_ok == 1'b0, 5, "tCCD_S: cross-BG WR immediately blocked");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TCCD_S - 1, 5, "tCCD_S: blocked for exactly P_TCCD_S-1 cycles");
        chk(tc_ok == 1'b1,            5, "tCCD_S: unblocked after tCCD_S cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T6: tCCD_L – CAS to CAS, same bank group
        //     WR → WR (same BG=0, diff bank); expected wait = P_TCCD_L - 1 = 4
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b00; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 6, "tCCD_L: trigger WR ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b00; tc_bank = 2'b11;
        chk(tc_ok == 1'b0, 6, "tCCD_L: same-BG WR immediately blocked");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TCCD_L - 1, 6, "tCCD_L: blocked for exactly P_TCCD_L-1 cycles");
        chk(tc_ok == 1'b1,            6, "tCCD_L: unblocked after tCCD_L cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T7: tWTR_S – WR to RD, different bank group
        //     Expected wait = P_TWTR_S - 1 = 4 cycles
        //     (P_TWTR_S=5 > P_TCCD_S=3 so tWTR_S is binding)
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b00; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 7, "tWTR_S: trigger WR ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_RD; tc_bank_group = 2'b10; tc_bank = 2'b10;
        chk(tc_ok == 1'b0, 7, "tWTR_S: cross-BG RD immediately blocked after WR");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TWTR_S - 1, 7, "tWTR_S: blocked for exactly P_TWTR_S-1 cycles");
        chk(tc_ok == 1'b1,            7, "tWTR_S: unblocked after tWTR_S cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T8: tWTR_L – WR to RD, same bank group
        //     Expected wait = P_TWTR_L - 1 = 6 cycles
        //     (P_TWTR_L=7 > P_TWTR_S=5, P_TCCD_L=5 so tWTR_L binds)
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b00; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 8, "tWTR_L: trigger WR ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_RD; tc_bank_group = 2'b00; tc_bank = 2'b11;
        chk(tc_ok == 1'b0, 8, "tWTR_L: same-BG RD immediately blocked after WR");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TWTR_L - 1, 8, "tWTR_L: blocked for exactly P_TWTR_L-1 cycles");
        chk(tc_ok == 1'b1,            8, "tWTR_L: unblocked after tWTR_L cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T9: tRCD – ACT to RD, same bank
        //     Expected wait = P_TRCD - 1 = 3 cycles
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b10; tc_bank = 2'b00;
        chk(tc_ok == 1'b1, 9, "tRCD: trigger ACT ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_RD; tc_bank_group = 2'b10; tc_bank = 2'b00;
        chk(tc_ok == 1'b0, 9, "tRCD: RD immediately blocked after ACT");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRCD - 1, 9, "tRCD: blocked for exactly P_TRCD-1 cycles");
        chk(tc_ok == 1'b1,          9, "tRCD: unblocked after tRCD cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T10: tRP – PRE to ACT, same bank
        //     Setup: ACT, drain P_TFAW cycles (ensures tRAS, tRC, tFAW
        //     all expire), issue PRE, then check second ACT is blocked.
        //     Expected wait = P_TRP - 1 = 4 cycles (only trp_cnt blocks)
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b10; tc_bank = 2'b01;
        chk(tc_ok == 1'b1, 10, "tRP: first ACT ok");
        @(posedge clk); #1;
        // Drain P_TFAW cycles: tras, trc, faw all expire (P_TFAW > all three)
        drain(P_TFAW);

        @(negedge clk);
        tc_cmd = CMD_PRE; tc_bank_group = 2'b10; tc_bank = 2'b01;
        chk(tc_ok == 1'b1, 10, "tRP: PRE ok (tras/trc/faw all expired)");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b10; tc_bank = 2'b01;
        // #1 needed here: the previous command (PRE) left tc_ok=1.
        // Even with continuous-assign tc_ok, Icarus Verilog defers the
        // wire update to the next delta cycle when the driving reg changes
        // in an initial block.  The #1 ensures tc_ok has settled before chk.
        #1;
        chk(tc_ok == 1'b0, 10, "tRP: second ACT immediately blocked after PRE");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRP - 1, 10, "tRP: blocked for exactly P_TRP-1 cycles");
        chk(tc_ok == 1'b1,         10, "tRP: unblocked after tRP cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T11: tRAS – ACT to PRE, same bank
        //     Expected wait = P_TRAS - 1 = 7 cycles
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b10; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 11, "tRAS: ACT ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_PRE; tc_bank_group = 2'b10; tc_bank = 2'b10;
        chk(tc_ok == 1'b0, 11, "tRAS: PRE immediately blocked after ACT");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRAS - 1, 11, "tRAS: blocked for exactly P_TRAS-1 cycles");
        chk(tc_ok == 1'b1,          11, "tRAS: unblocked after tRAS cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T12: tRC – ACT to ACT, same bank
        //     P_TRC=13 > P_TFAW=12 so tRC is binding.
        //     Expected wait = P_TRC - 1 = 12 cycles
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b11; tc_bank = 2'b01;
        chk(tc_ok == 1'b1, 12, "tRC: first ACT ok");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_ACT; tc_bank_group = 2'b11; tc_bank = 2'b01;
        chk(tc_ok == 1'b0, 12, "tRC: same-bank second ACT immediately blocked");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRC - 1, 12, "tRC: blocked for exactly P_TRC-1 cycles");
        chk(tc_ok == 1'b1,         12, "tRC: unblocked after tRC cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T13: tRTP – RD to PRE, same bank
        //     Expected wait = P_TRTP - 1 = 3 cycles
        //     (Fresh bank: no ACT → tras=0; trtp is the only block)
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_RD; tc_bank_group = 2'b11; tc_bank = 2'b10;
        chk(tc_ok == 1'b1, 13, "tRTP: trigger RD ok (fresh bank, trcd=0)");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_PRE; tc_bank_group = 2'b11; tc_bank = 2'b10;
        chk(tc_ok == 1'b0, 13, "tRTP: PRE immediately blocked after RD");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TRTP - 1, 13, "tRTP: blocked for exactly P_TRTP-1 cycles");
        chk(tc_ok == 1'b1,          13, "tRTP: unblocked after tRTP cycles");
        @(posedge clk); #1;
        drain(20);

        // ===========================================================
        // T14: tWR – WR to PRE, same bank
        //     Expected wait = P_TWR - 1 = 5 cycles
        //     (Fresh bank: tras=0; twr is the only block)
        // ===========================================================
        @(negedge clk);
        tc_cmd = CMD_WR; tc_bank_group = 2'b11; tc_bank = 2'b11;
        chk(tc_ok == 1'b1, 14, "tWR: trigger WR ok (fresh bank, trcd=0)");
        @(posedge clk); #1;

        @(negedge clk);
        tc_cmd = CMD_PRE; tc_bank_group = 2'b11; tc_bank = 2'b11;
        chk(tc_ok == 1'b0, 14, "tWR: PRE immediately blocked after WR");
        count_wait(wait_cnt);
        chk(wait_cnt == P_TWR - 1, 14, "tWR: blocked for exactly P_TWR-1 cycles");
        chk(tc_ok == 1'b1,         14, "tWR: unblocked after tWR cycles");
        @(posedge clk); #1;

        // ===========================================================
        // Summary
        // ===========================================================
        $display("--------------------------------------------");
        $display("timing_ctrl_tb: %0d PASSED, %0d FAILED",
                 pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "timing_ctrl_tb: simulation FAILED");
        $finish;
    end

endmodule
