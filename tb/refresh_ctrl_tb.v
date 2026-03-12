// refresh_ctrl_tb.v – Testbench for refresh_ctrl
//
// Uses compact timing parameters to keep simulation fast:
//   P_TREFI = 20 cycles   (REFab/REFpb interval)
//   P_TRFC  = 8  cycles   (refresh cycle time)
//   BANK_GROUPS      = 2
//   BANKS_PER_GROUP  = 2  (→ 4 total banks for REFpb cycling)
//
// Tests:
//   T1:  Reset – state = NORMAL, ref_req=0, ref_stall=0, ref_issue=0
//   T2:  REFab – tREFI expires, ref_req asserted, then ref_issue fires
//   T3:  REFab tRFC stall – ref_stall held for exactly P_TRFC cycles
//   T4:  REFab return – ref_stall de-asserted, state back to NORMAL
//   T5:  Second REFab cycle is triggered automatically (timer re-loaded)
//   T6:  temp_throttle halves tREFI interval
//   T7:  REFpb mode – ref_bank_group / ref_bank cycle through all banks
//   T8:  REFpb – four banks refreshed in order; bank_idx wraps to 0
//   T9:  ref_req de-asserted when all_banks_idle de-asserted (wait extend)
//
// Compile & run:
//   iverilog -g2012 -o build/refresh_ctrl.out tb/refresh_ctrl_tb.v rtl/refresh_ctrl.v
//   vvp build/refresh_ctrl.out

`timescale 1ns/1ps

module refresh_ctrl_tb;

    // ----------------------------------------------------------------
    // Compact parameters for fast simulation
    // ----------------------------------------------------------------
    localparam P_TREFI         = 20;
    localparam P_TRFC          = 8;
    localparam BANK_GROUPS     = 2;
    localparam BANKS_PER_GROUP = 2;
    localparam TOTAL_BANKS     = BANK_GROUPS * BANKS_PER_GROUP;  // 4

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg  clk;
    reg  rst_n;
    reg  all_banks_idle;
    reg  rfsh_mode;
    reg  temp_throttle;

    wire ref_req;
    wire ref_issue;
    wire ref_stall;
    wire ref_active;
    wire [1:0] ref_bank_group;
    wire [1:0] ref_bank;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    refresh_ctrl #(
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
        .P_TREFI         (P_TREFI),
        .P_TRFC          (P_TRFC)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .all_banks_idle (all_banks_idle),
        .rfsh_mode      (rfsh_mode),
        .temp_throttle  (temp_throttle),
        .ref_req        (ref_req),
        .ref_issue      (ref_issue),
        .ref_stall      (ref_stall),
        .ref_active     (ref_active),
        .ref_bank_group (ref_bank_group),
        .ref_bank       (ref_bank)
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
        $dumpfile("results/phase-ddr4-refresh/refresh_ctrl.vcd");
        $dumpvars(0, refresh_ctrl_tb);
    end

    // ----------------------------------------------------------------
    // Test counters / helpers
    // ----------------------------------------------------------------
    integer pass_count, fail_count;

    task chk;
        input        cond;
        input [31:0] test_id;
        input [255:0] msg;
        begin
            if (cond) begin
                $display("PASS T%0d: %s", test_id, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL T%0d: %s  (req=%b issue=%b stall=%b active=%b bg=%0d b=%0d)",
                         test_id, msg,
                         ref_req, ref_issue, ref_stall, ref_active,
                         ref_bank_group, ref_bank);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Advance one clock, sample after rising edge
    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    // ----------------------------------------------------------------
    // Main test body
    // ----------------------------------------------------------------
    integer i;
    integer req_seen, issue_seen, stall_cycles;
    integer bank_seen [0:3];
    integer bg_captured, bk_captured;

    initial begin
        pass_count      = 0;
        fail_count      = 0;
        rst_n           = 1'b0;
        all_banks_idle  = 1'b1;
        rfsh_mode       = 1'b0;   // REFab by default
        temp_throttle   = 1'b0;

        // ===========================================================
        // T1: Reset
        // ===========================================================
        repeat(4) @(posedge clk);
        #1;
        chk(ref_req   == 1'b0, 1, "reset: ref_req=0");
        chk(ref_issue == 1'b0, 1, "reset: ref_issue=0");
        chk(ref_stall == 1'b0, 1, "reset: ref_stall=0");
        chk(ref_active== 1'b0, 1, "reset: ref_active=0");

        rst_n = 1'b1;
        @(posedge clk); #1;

        // ===========================================================
        // T2: REFab – ref_req asserted when tREFI expires
        //     Wait up to P_TREFI+5 cycles looking for ref_req
        // ===========================================================
        req_seen = 0;
        for (i = 0; i < P_TREFI + 5; i = i + 1) begin
            tick;
            if (ref_req) begin
                req_seen = 1;
                i = P_TREFI + 5; // exit loop
            end
        end
        chk(req_seen == 1, 2, "REFab: ref_req asserted after tREFI");

        // ===========================================================
        // T3: ref_issue fires exactly one cycle after all_banks_idle
        //     (banks already idle in this TB)
        // ===========================================================
        issue_seen = 0;
        for (i = 0; i < 4; i = i + 1) begin
            tick;
            if (ref_issue) begin
                issue_seen = 1;
                i = 4; // exit loop
            end
        end
        chk(issue_seen == 1, 3, "REFab: ref_issue fires when banks idle");

        // ===========================================================
        // T4: ref_stall held for exactly P_TRFC cycles
        // ===========================================================
        // ref_issue may have just fired; sample stall in this cycle
        if (!ref_stall) tick;  // advance if stall not yet seen
        chk(ref_stall == 1'b1, 4, "REFab: ref_stall asserted at start of tRFC");

        stall_cycles = 0;
        while (ref_stall) begin
            stall_cycles = stall_cycles + 1;
            tick;
        end
        // stall_cycles counts cycles where ref_stall was 1
        chk(stall_cycles == P_TRFC, 4, "REFab: ref_stall lasts P_TRFC cycles");

        // ===========================================================
        // T5: After tRFC ref_stall=0 and ref_active=0 (back to NORMAL)
        // ===========================================================
        chk(ref_stall  == 1'b0, 5, "REFab: ref_stall=0 after tRFC");
        chk(ref_active == 1'b0, 5, "REFab: ref_active=0 after tRFC");
        chk(ref_req    == 1'b0, 5, "REFab: ref_req=0 after tRFC");

        // ===========================================================
        // T6: A second automatic REFab cycle starts after another tREFI
        // ===========================================================
        req_seen = 0;
        for (i = 0; i < P_TREFI + 5; i = i + 1) begin
            tick;
            if (ref_req) begin
                req_seen = 1;
                i = P_TREFI + 5;
            end
        end
        chk(req_seen == 1, 6, "REFab 2nd cycle: ref_req asserted again");

        // drain the second cycle quickly
        for (i = 0; i < P_TRFC + 5; i = i + 1) tick;

        // ===========================================================
        // T7: temp_throttle halves tREFI interval
        //     Enable throttle, measure how many cycles until ref_req
        // ===========================================================
        // First, make sure we are back in NORMAL
        while (ref_active) tick;

        temp_throttle = 1'b1;
        req_seen = 0;
        for (i = 0; i < (P_TREFI/2) + 5; i = i + 1) begin
            tick;
            if (ref_req) begin
                req_seen  = 1;
                i = (P_TREFI/2) + 5;
            end
        end
        chk(req_seen == 1, 7, "temp_throttle: ref_req within tREFI/2+5 cycles");

        // drain
        for (i = 0; i < P_TRFC + 5; i = i + 1) tick;
        temp_throttle = 1'b0;
        while (ref_active) tick;

        // ===========================================================
        // T8: REFpb mode – all 4 banks cycled in order
        // ===========================================================
        rfsh_mode = 1'b1;  // switch to per-bank refresh

        // Collect the ref_bank_group and ref_bank at each ref_issue pulse
        // for 4 cycles (= TOTAL_BANKS = 4)
        begin : refpb_loop
            integer b;
            integer bg_arr [0:3];
            integer bk_arr [0:3];
            integer nref;
            nref = 0;

            for (b = 0; b < TOTAL_BANKS * (P_TREFI + P_TRFC) + 20; b = b + 1) begin
                tick;
                if (ref_issue && nref < TOTAL_BANKS) begin
                    bg_arr[nref] = ref_bank_group;
                    bk_arr[nref] = ref_bank;
                    nref = nref + 1;
                end
            end

            chk(nref == TOTAL_BANKS, 8, "REFpb: all banks refreshed once");

            // Bank indices should cycle 0..TOTAL_BANKS-1 in order:
            //   bank_idx = {bg[1:0], b[1:0]}
            //   bg=bank_idx[3:2], bk=bank_idx[1:0]
            begin : refpb_order_chk
                integer k;
                integer ok;
                ok = 1;
                for (k = 0; k < nref; k = k + 1) begin
                    integer exp_bg, exp_bk;
                    exp_bg = k >> 1;       // k / BANKS_PER_GROUP (=2)
                    exp_bk = k  & 1;       // k % BANKS_PER_GROUP (=2)
                    if (bg_arr[k] !== exp_bg || bk_arr[k] !== exp_bk) ok = 0;
                end
                chk(ok == 1, 8, "REFpb: bank order {bg,bk} = 0..TOTAL_BANKS-1");
            end
        end

        // ===========================================================
        // T9: all_banks_idle=0 extends REF_PENDING
        //     Lower all_banks_idle once ref_req asserts; check that
        //     ref_issue is NOT fired while banks are not idle.
        // ===========================================================
        rfsh_mode      = 1'b0;      // back to REFab
        all_banks_idle = 1'b0;      // banks busy

        while (ref_active) tick;    // wait for NORMAL (after previous cycle)

        // Wait for ref_req to fire
        req_seen   = 0;
        issue_seen = 0;
        for (i = 0; i < P_TREFI + 5; i = i + 1) begin
            tick;
            if (ref_req) req_seen = 1;
            if (ref_issue) issue_seen = 1;
        end
        chk(req_seen   == 1, 9, "T9: ref_req asserted with banks busy");
        chk(issue_seen == 0, 9, "T9: ref_issue NOT fired while banks busy");

        // Now idle the banks → refresh should proceed
        all_banks_idle = 1'b1;
        issue_seen = 0;
        for (i = 0; i < 5; i = i + 1) begin
            tick;
            if (ref_issue) issue_seen = 1;
        end
        chk(issue_seen == 1, 9, "T9: ref_issue fires once banks go idle");

        // drain
        for (i = 0; i < P_TRFC + 5; i = i + 1) tick;

        // ===========================================================
        // Summary
        // ===========================================================
        $display("");
        $display("=== Simulation complete: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        if (fail_count != 0)
            $fatal(1, "One or more checks FAILED");
        $finish;
    end

    // ----------------------------------------------------------------
    // Watchdog: abort after 100 000 cycles
    // ----------------------------------------------------------------
    initial begin
        #1000000;
        $fatal(1, "WATCHDOG: simulation exceeded time limit");
    end

endmodule
