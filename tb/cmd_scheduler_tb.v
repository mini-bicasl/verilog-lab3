// cmd_scheduler_tb.v – Testbench for cmd_scheduler
//
// The testbench drives tc_ok directly (bypassing a real timing_ctrl) so that
// the scheduler's FSM and open-row policy can be verified in isolation.
//
// Parameters used:
//   AXI_ADDR_W      = 34
//   ROW_ADDR_W      = 11  (11-bit row to match address decode: addr[32:22])
//   COL_ADDR_W      = 10  (addr[17:8])
//   BANK_GROUPS     = 2
//   BANKS_PER_GROUP = 2   (4 total banks for fast simulation)
//
// Tests:
//   T1: Reset – dram_valid=0, arb_ready=1 (IDLE), tc_cmd=NOP
//   T2: Open-row miss (bank IDLE) → scheduler issues ACT then RD
//   T3: Open-row hit (same bank, same row) → direct RD without ACT
//   T4: Row conflict (same bank, different row) → PRE → ACT → WR
//   T5: tc_ok=0 stalls the scheduler until tc_ok goes high
//   T6: Refresh preemption: ref_issue causes REF on dram bus; row_open cleared
//   T7: ref_req blocks new requests via arb_ready deassertion
//   T8: Multiple banks: concurrent open rows per bank tracked independently
//
// Compile & run:
//   iverilog -g2012 -o build/cmd_scheduler.out tb/cmd_scheduler_tb.v rtl/cmd_scheduler.v
//   vvp build/cmd_scheduler.out

`timescale 1ns/1ps

module cmd_scheduler_tb;

    // ----------------------------------------------------------------
    // Parameters
    // ----------------------------------------------------------------
    localparam AXI_ADDR_W      = 34;
    localparam AXI_ID_W        = 4;
    localparam BANK_GROUPS     = 2;
    localparam BANKS_PER_GROUP = 2;
    localparam ROW_ADDR_W      = 11;  // matches addr[32:22] decode
    localparam COL_ADDR_W      = 10;

    // ----------------------------------------------------------------
    // Command encodings (mirror RTL localparams)
    // ----------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg                   clk;
    reg                   rst_n;

    reg                   arb_valid;
    wire                  arb_ready;
    reg                   arb_is_write;
    reg  [AXI_ADDR_W-1:0] arb_addr;

    reg                   ref_req;
    reg                   ref_issue;

    reg                   tc_ok;
    wire [2:0]            tc_cmd;
    wire [1:0]            tc_bank_group;
    wire [1:0]            tc_bank;

    wire [2:0]            dram_cmd;
    wire [1:0]            dram_bank_group;
    wire [1:0]            dram_bank;
    wire [ROW_ADDR_W-1:0] dram_row_addr;
    wire [COL_ADDR_W-1:0] dram_col_addr;
    wire                  dram_valid;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    cmd_scheduler #(
        .AXI_ADDR_W      (AXI_ADDR_W),
        .AXI_ID_W        (AXI_ID_W),
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
        .ROW_ADDR_W      (ROW_ADDR_W),
        .COL_ADDR_W      (COL_ADDR_W)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .arb_valid      (arb_valid),
        .arb_ready      (arb_ready),
        .arb_is_write   (arb_is_write),
        .arb_addr       (arb_addr),
        .ref_req        (ref_req),
        .ref_issue      (ref_issue),
        .tc_cmd         (tc_cmd),
        .tc_bank_group  (tc_bank_group),
        .tc_bank        (tc_bank),
        .tc_ok          (tc_ok),
        .dram_cmd       (dram_cmd),
        .dram_bank_group(dram_bank_group),
        .dram_bank      (dram_bank),
        .dram_row_addr  (dram_row_addr),
        .dram_col_addr  (dram_col_addr),
        .dram_valid     (dram_valid)
    );

    // ----------------------------------------------------------------
    // Clock generation – 10 ns period (100 MHz)
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // VCD waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-sched/cmd_scheduler.vcd");
        $dumpvars(0, cmd_scheduler_tb);
    end

    // ----------------------------------------------------------------
    // Helper: build a 34-bit address from (bg, bank, row, col)
    // Encoding per docs/ARCHITECTURE.md §7:
    //   [32:22] row, [21:20] bg, [19:18] bank, [17:8] col
    // ----------------------------------------------------------------
    function [AXI_ADDR_W-1:0] make_addr;
        input [1:0]   bg;
        input [1:0]   bank;
        input [10:0]  row;  // 11 bits
        input [9:0]   col;  // 10 bits
        begin
            make_addr = 34'b0;
            make_addr[32:22] = row;
            make_addr[21:20] = bg;
            make_addr[19:18] = bank;
            make_addr[17:8]  = col;
        end
    endfunction

    // ----------------------------------------------------------------
    // Check helper
    // ----------------------------------------------------------------
    integer pass_count, fail_count;

    task chk;
        input        cond;
        input [31:0] tid;
        input [239:0] msg;
        begin
            if (cond) begin
                $display("PASS T%0d: %s", tid, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL T%0d: %s  (dram_valid=%b dram_cmd=%0d tc_cmd=%0d arb_ready=%b)",
                         tid, msg,
                         dram_valid, dram_cmd, tc_cmd, arb_ready);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task clk_cycle;
        begin
            @(posedge clk); #1;
        end
    endtask

    // Send one arbitrated request and wait one cycle for scheduler to latch it
    task send_req;
        input                   is_wr;
        input [AXI_ADDR_W-1:0]  addr;
        begin
            @(negedge clk);
            arb_valid    = 1'b1;
            arb_is_write = is_wr;
            arb_addr     = addr;
            @(posedge clk); #1;
            arb_valid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Main test sequencer
    // ----------------------------------------------------------------
    reg [AXI_ADDR_W-1:0] addr_a, addr_b;
    integer i;

    initial begin
        pass_count   = 0;
        fail_count   = 0;

        arb_valid    = 1'b0;
        arb_is_write = 1'b0;
        arb_addr     = {AXI_ADDR_W{1'b0}};
        ref_req      = 1'b0;
        ref_issue    = 1'b0;
        tc_ok        = 1'b1;   // timing always OK unless test overrides

        // =============================================================
        // T1: Reset
        // =============================================================
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        #1;
        chk(dram_valid == 1'b0, 1, "reset: dram_valid=0");
        chk(arb_ready  == 1'b1, 1, "reset: arb_ready=1 (in IDLE)");
        chk(tc_cmd     == CMD_NOP, 1, "reset: tc_cmd=NOP");

        @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // =============================================================
        // T2: Open-row miss (bank idle) → ACT then RD
        // Bank 0 (bg=0, bank=0), row=11'h0AA, col=10'h055
        // =============================================================
        addr_a = make_addr(2'd0, 2'd0, 11'h0AA, 10'h055);
        send_req(1'b0, addr_a);   // read request

        // One cycle later: scheduler should be in S_ACT proposing ACT
        chk(tc_cmd == CMD_ACT, 2, "miss: tc_cmd=ACT after latch");
        chk(dram_valid == 1'b1, 2, "miss: ACT issued (tc_ok=1)");
        chk(dram_cmd   == CMD_ACT, 2, "miss: dram_cmd=ACT");
        chk(dram_bank_group == 2'd0, 2, "miss: dram_bank_group=0");
        chk(dram_bank       == 2'd0, 2, "miss: dram_bank=0");
        chk(dram_row_addr   == {{(ROW_ADDR_W-11){1'b0}}, 11'h0AA},
            2, "miss: dram_row_addr correct");

        // Next cycle: scheduler should be in S_DATA proposing RD
        clk_cycle;
        chk(tc_cmd     == CMD_RD,  2, "miss: tc_cmd=RD after ACT");
        chk(dram_valid == 1'b1,    2, "miss: RD issued");
        chk(dram_cmd   == CMD_RD,  2, "miss: dram_cmd=RD");
        chk(dram_col_addr == 10'h055, 2, "miss: dram_col_addr correct");

        // Next cycle: back to IDLE
        clk_cycle;
        chk(arb_ready  == 1'b1, 2, "miss: back to IDLE (arb_ready=1)");
        chk(dram_valid == 1'b0, 2, "miss: dram_valid=0 in IDLE");

        // =============================================================
        // T3: Open-row HIT – same bank, same row → direct RD
        // =============================================================
        send_req(1'b0, addr_a);   // same address again

        // Should go straight to S_DATA (same row is open)
        chk(tc_cmd     == CMD_RD,  3, "hit: tc_cmd=RD directly (no ACT)");
        chk(dram_cmd   == CMD_RD,  3, "hit: dram_cmd=RD");
        chk(dram_valid == 1'b1,    3, "hit: dram_valid=1 immediately");

        clk_cycle;
        chk(arb_ready == 1'b1, 3, "hit: back to IDLE");

        // =============================================================
        // T4: Row conflict – same bank, different row → PRE → ACT → WR
        // =============================================================
        addr_b = make_addr(2'd0, 2'd0, 11'h0BB, 10'h033);  // same bank, diff row
        send_req(1'b1, addr_b);   // write request

        // Should be in S_PRE proposing PRECHARGE
        chk(tc_cmd     == CMD_PRE, 4, "conflict: tc_cmd=PRE first");
        chk(dram_valid == 1'b1,    4, "conflict: PRE issued");
        chk(dram_cmd   == CMD_PRE, 4, "conflict: dram_cmd=PRE");

        // Next: S_ACT
        clk_cycle;
        chk(tc_cmd   == CMD_ACT, 4, "conflict: tc_cmd=ACT after PRE");
        chk(dram_cmd == CMD_ACT, 4, "conflict: dram_cmd=ACT");
        chk(dram_row_addr == {{(ROW_ADDR_W-11){1'b0}}, 11'h0BB},
            4, "conflict: new row address in ACT");

        // Next: S_DATA
        clk_cycle;
        chk(tc_cmd   == CMD_WR, 4, "conflict: tc_cmd=WR after ACT");
        chk(dram_cmd == CMD_WR, 4, "conflict: dram_cmd=WR");
        chk(dram_col_addr == 10'h033, 4, "conflict: col_addr correct");

        // Back to IDLE
        clk_cycle;
        chk(arb_ready == 1'b1, 4, "conflict: back to IDLE");

        // =============================================================
        // T5: Timing stall – tc_ok=0 prevents command issuance
        // =============================================================
        tc_ok = 1'b0;  // stall all commands

        addr_a = make_addr(2'd1, 2'd0, 11'h010, 10'h020);
        send_req(1'b0, addr_a);   // new bank (bg=1,bank=0), read

        // Scheduler in S_ACT, tc_ok=0 → no dram_valid
        chk(tc_cmd == CMD_ACT, 5, "stall: tc_cmd=ACT proposed");
        #1;
        chk(dram_valid == 1'b0, 5, "stall: dram_valid=0 (tc_ok=0)");

        repeat(2) clk_cycle;
        chk(dram_valid == 1'b0, 5, "stall: still stalled after 2 more cycles");
        chk(tc_cmd     == CMD_ACT, 5, "stall: tc_cmd still ACT");

        // Release stall
        tc_ok = 1'b1;
        #1;
        chk(dram_valid == 1'b1, 5, "stall released: ACT issues immediately");
        chk(dram_cmd   == CMD_ACT, 5, "stall released: cmd=ACT");

        clk_cycle;
        chk(dram_cmd == CMD_RD, 5, "stall: RD follows ACT");
        clk_cycle;
        chk(arb_ready == 1'b1, 5, "stall: back to IDLE");

        // =============================================================
        // T6: Refresh preemption – ref_issue causes REF on dram bus
        // Use a fresh bank (bg=2,ba=0 = flat index 8) to open a row
        // before issuing refresh, so we can verify row_open is cleared.
        // =============================================================
        // Open a fresh bank (bg=2, ba=0) → flat index 8, never used before
        addr_a = make_addr(2'd2, 2'd0, 11'h0CC, 10'h010);
        send_req(1'b0, addr_a);
        // bank is idle → miss: ACT then RD = 2 commands
        repeat(2) clk_cycle;
        chk(arb_ready == 1'b1, 6, "pre-ref: row opened, back to IDLE");

        // Fire ref_issue for one cycle
        @(negedge clk); ref_issue = 1'b1;
        @(posedge clk); #1;
        chk(dram_valid == 1'b1,    6, "ref_issue: dram_valid=1");
        chk(dram_cmd   == CMD_REF, 6, "ref_issue: dram_cmd=REF");
        chk(tc_cmd     == CMD_REF, 6, "ref_issue: tc_cmd=REF");

        @(negedge clk); ref_issue = 1'b0;
        @(posedge clk); #1;
        chk(dram_valid == 1'b0, 6, "post-ref: dram_valid=0");
        chk(arb_ready  == 1'b1, 6, "post-ref: arb_ready=1 (IDLE)");

        // After REF, bank 0 should have row_open cleared; next request
        // must issue ACT again (not a hit)
        addr_a = make_addr(2'd0, 2'd0, 11'h0CC, 10'h010);
        send_req(1'b0, addr_a);
        chk(tc_cmd == CMD_ACT, 6, "post-ref: ACT required again (row cleared)");
        repeat(2) clk_cycle;  // finish the sequence

        // =============================================================
        // T7: ref_req blocks arb_ready
        // =============================================================
        @(negedge clk); ref_req = 1'b1;
        @(posedge clk); #1;
        chk(arb_ready == 1'b0, 7, "ref_req: arb_ready=0 blocked");

        @(negedge clk); ref_req = 1'b0;
        @(posedge clk); #1;
        chk(arb_ready == 1'b1, 7, "ref_req released: arb_ready=1");

        clk_cycle;

        // =============================================================
        // T8: Multiple banks – open rows tracked independently.
        // Use fresh banks (bg=3,ba=0 and bg=3,ba=1 = flat indices 12/13)
        // that have never been opened in this simulation run.
        // =============================================================
        // Open bank (bg=3, ba=0) with row 0x111 – bank is idle (miss: ACT+RD)
        addr_a = make_addr(2'd3, 2'd0, 11'h111, 10'h001);
        send_req(1'b0, addr_a);
        repeat(2) clk_cycle;  // S_ACT→S_DATA, S_DATA→S_IDLE

        // Open bank (bg=3, ba=1) with row 0x222 – bank is idle (miss: ACT+WR)
        addr_b = make_addr(2'd3, 2'd1, 11'h222, 10'h002);
        send_req(1'b1, addr_b);
        repeat(2) clk_cycle;  // ACT + WR + back to IDLE

        // Hit bank (bg=3, ba=0) – same row 0x111 → direct RD
        addr_a = make_addr(2'd3, 2'd0, 11'h111, 10'h003);
        send_req(1'b0, addr_a);
        chk(tc_cmd == CMD_RD, 8, "multi-bank: bank(3,0) hit -> direct RD");
        clk_cycle;
        chk(arb_ready == 1'b1, 8, "multi-bank: back to IDLE after RD");

        // Hit bank (bg=3, ba=1) – same row 0x222 → direct WR
        addr_b = make_addr(2'd3, 2'd1, 11'h222, 10'h004);
        send_req(1'b1, addr_b);
        chk(tc_cmd == CMD_WR, 8, "multi-bank: bank(3,1) hit -> direct WR");
        clk_cycle;
        chk(arb_ready == 1'b1, 8, "multi-bank: back to IDLE after WR");

        // =============================================================
        // Summary
        // =============================================================
        $display("--------------------------------------------");
        $display("cmd_scheduler_tb: %0d PASSED, %0d FAILED",
                 pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "cmd_scheduler_tb: simulation FAILED");
        $finish;
    end

endmodule
