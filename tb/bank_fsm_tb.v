// bank_fsm_tb.v – Testbench for bank_fsm (per-bank DDR4 state machine)
//
// Uses compact timing parameters to keep simulation fast:
//   P_TRCD = 4 cycles (ACT to RD/WR)
//   P_TRAS = 8 cycles (minimum active time)
//   P_TRP  = 4 cycles (precharge recovery)
//
// Tests:
//   T1: Reset – state = IDLE, fsm_ready = 1, row_active = 0, open_row = 0
//   T2: ACT in IDLE – transitions to ACTIVATING, row address latched
//   T3: ACTIVATING dwell – exactly P_TRCD cycles before entering ACTIVE
//   T4: tRAS enforcement – PRE issued immediately on entering ACTIVE is blocked
//       (tras_ok is guaranteed 0 here since P_TRAS > P_TRCD)
//   T5: ACTIVE state – RD/WR do not cause a state transition
//   T6: tras_ok asserts after P_TRAS cycles; PRE → PRECHARGING
//   T7: PRECHARGING dwell – exactly P_TRP cycles
//   T8: Return to IDLE after tRP
//   T9: Full second cycle – ACT → ACTIVE → PRE → IDLE
//  T10: open_row preserved across multiple RD/WR commands
//
// Compile & run:
//   iverilog -g2012 -o build/bank_fsm.out tb/bank_fsm_tb.v rtl/bank_fsm.v
//   vvp build/bank_fsm.out

`timescale 1ns/1ps

module bank_fsm_tb;

    // ----------------------------------------------------------------
    // Parameters under test (compact values for simulation speed)
    // ----------------------------------------------------------------
    localparam P_TRCD     = 4;
    localparam P_TRAS     = 8;
    localparam P_TRP      = 4;
    localparam ROW_ADDR_W = 17;

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg                   clk;
    reg                   rst_n;
    reg  [2:0]            cmd_in;
    reg  [ROW_ADDR_W-1:0] row_addr_in;
    reg                   cmd_valid;

    wire                   fsm_ready;
    wire [ROW_ADDR_W-1:0]  open_row;
    wire                   row_active;
    wire                   tras_ok;
    wire [1:0]             state_out;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    bank_fsm #(
        .ROW_ADDR_W (ROW_ADDR_W),
        .P_TRCD     (P_TRCD),
        .P_TRAS     (P_TRAS),
        .P_TRP      (P_TRP)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_in      (cmd_in),
        .row_addr_in (row_addr_in),
        .cmd_valid   (cmd_valid),
        .fsm_ready   (fsm_ready),
        .open_row    (open_row),
        .row_active  (row_active),
        .tras_ok     (tras_ok),
        .state_out   (state_out)
    );

    // ----------------------------------------------------------------
    // Command / state constants (mirror RTL localparams)
    // ----------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;

    localparam S_IDLE        = 2'd0;
    localparam S_ACTIVATING  = 2'd1;
    localparam S_ACTIVE      = 2'd2;
    localparam S_PRECHARGING = 2'd3;

    // ----------------------------------------------------------------
    // Clock generation – 10 ns period (100 MHz)
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // VCD waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-bank/bank_fsm.vcd");
        $dumpvars(0, bank_fsm_tb);
    end

    // ----------------------------------------------------------------
    // Check helper
    // ----------------------------------------------------------------
    integer pass_count, fail_count;

    task chk;
        input        cond;
        input [31:0] test_id;
        input [159:0] msg;
        begin
            if (cond) begin
                $display("PASS T%0d: %s", test_id, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL T%0d: %s  (state=%0d rdy=%b act=%b tok=%b)",
                         test_id, msg, state_out, fsm_ready, row_active, tras_ok);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // send_cmd: set cmd on next clock boundary, returns after the
    // *following* rising edge (i.e. the command is captured by DUT).
    // cmd_valid is left HIGH on exit; caller must deassert.
    // ----------------------------------------------------------------
    task send_cmd;
        input [2:0]            c;
        input [ROW_ADDR_W-1:0] raddr;
        begin
            // Set up command between clock edges for clean hold time
            @(negedge clk);
            cmd_in      = c;
            row_addr_in = raddr;
            cmd_valid   = 1'b1;
            // Advance past the next rising edge
            @(posedge clk); #1;
        end
    endtask

    task idle_cycle;
        begin
            @(negedge clk);
            cmd_valid = 1'b0;
            cmd_in    = CMD_NOP;
            @(posedge clk); #1;
        end
    endtask

    // ----------------------------------------------------------------
    // Main test sequencer
    // ----------------------------------------------------------------
    integer i;
    reg [ROW_ADDR_W-1:0] test_row;

    initial begin
        pass_count  = 0;
        fail_count  = 0;

        cmd_in      = CMD_NOP;
        row_addr_in = {ROW_ADDR_W{1'b0}};
        cmd_valid   = 1'b0;

        // ===========================================================
        // T1: Reset
        // ===========================================================
        rst_n = 1'b0;
        repeat(4) @(posedge clk);
        #1;
        chk(state_out  == S_IDLE,                 1, "reset: state=IDLE");
        chk(fsm_ready  == 1'b1,                   1, "reset: fsm_ready=1");
        chk(row_active == 1'b0,                   1, "reset: row_active=0");
        chk(open_row   == {ROW_ADDR_W{1'b0}},     1, "reset: open_row=0");

        @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ===========================================================
        // T2: ACT in IDLE -> ACTIVATING; row address latched
        // ===========================================================
        test_row = 17'h1A5B3;
        send_cmd(CMD_ACT, test_row);
        cmd_valid = 1'b0;
        chk(state_out == S_ACTIVATING, 2, "post-ACT: state=ACTIVATING");
        chk(open_row  == test_row,     2, "post-ACT: open_row latched");
        chk(fsm_ready == 1'b0,        2, "post-ACT: fsm_ready=0");

        // ===========================================================
        // T3: ACTIVATING dwell – P_TRCD cycles exactly
        //   T2 consumed 1 cycle; need P_TRCD-2 more in ACTIVATING,
        //   then 1 more to see ACTIVE.
        // ===========================================================
        repeat(P_TRCD - 2) begin
            idle_cycle;
            chk(state_out == S_ACTIVATING, 3, "ACTIVATING dwell");
            chk(fsm_ready == 1'b0,         3, "ACTIVATING: fsm_ready=0");
        end

        // Next cycle: FSM should move to ACTIVE
        idle_cycle;
        chk(state_out == S_ACTIVE, 3, "after tRCD: state=ACTIVE");
        chk(fsm_ready == 1'b1,    3, "ACTIVE: fsm_ready=1");
        chk(row_active == 1'b1,   3, "ACTIVE: row_active=1");

        // ===========================================================
        // T4: tRAS enforcement – premature PRE is blocked
        //   tras_ok MUST be 0 here (P_TRAS > P_TRCD, guaranteed by
        //   JEDEC: tRAS min > tRCD min). Assert this is true first.
        // ===========================================================
        chk(tras_ok == 1'b0, 4, "tRAS not yet satisfied on ACTIVE entry");

        // Issue PRE while tras_ok = 0 – must be silently discarded
        send_cmd(CMD_PRE, {ROW_ADDR_W{1'b0}});
        cmd_valid = 1'b0;
        chk(state_out == S_ACTIVE, 4, "PRE before tRAS: state stays ACTIVE");
        chk(row_active == 1'b1,    4, "PRE before tRAS: row still active");

        // ===========================================================
        // T5: RD and WR in ACTIVE – no state change
        // ===========================================================
        send_cmd(CMD_RD, test_row);
        cmd_valid = 1'b0;
        chk(state_out == S_ACTIVE, 5, "RD: state remains ACTIVE");

        send_cmd(CMD_WR, test_row);
        cmd_valid = 1'b0;
        chk(state_out == S_ACTIVE, 5, "WR: state remains ACTIVE");

        // ===========================================================
        // T6: tras_ok asserts after P_TRAS total cycles; PRE accepted
        // ===========================================================
        i = 0;
        while (!tras_ok && i < 64) begin
            idle_cycle;
            i = i + 1;
        end
        chk(tras_ok == 1'b1, 6, "tRAS satisfied: tras_ok=1");

        // Issue PRE now that tras_ok is high
        send_cmd(CMD_PRE, {ROW_ADDR_W{1'b0}});
        cmd_valid = 1'b0;
        chk(state_out == S_PRECHARGING, 6, "post-PRE: state=PRECHARGING");
        chk(fsm_ready  == 1'b0,         6, "PRECHARGING: fsm_ready=0");
        chk(row_active == 1'b0,         6, "PRECHARGING: row_active=0");

        // ===========================================================
        // T7: PRECHARGING dwell – P_TRP cycles
        //   T6 consumed 1 cycle; check P_TRP-2 more are PRECHARGING,
        //   then 1 more should be IDLE.
        // ===========================================================
        repeat(P_TRP - 2) begin
            idle_cycle;
            chk(state_out == S_PRECHARGING, 7, "PRECHARGING dwell");
            chk(fsm_ready  == 1'b0,          7, "PRECHARGING: fsm_ready=0");
        end

        // ===========================================================
        // T8: After tRP – state = IDLE
        // ===========================================================
        idle_cycle;
        chk(state_out == S_IDLE, 8, "after tRP: state=IDLE");
        chk(fsm_ready == 1'b1,   8, "IDLE: fsm_ready=1");
        chk(row_active == 1'b0,  8, "IDLE: row_active=0");

        // ===========================================================
        // T9: Full second ACT→ACTIVE→PRE→IDLE cycle
        // ===========================================================
        test_row = 17'h0F0F0;
        send_cmd(CMD_ACT, test_row);
        cmd_valid = 1'b0;

        // Wait for ACTIVE
        i = 0;
        while (state_out != S_ACTIVE && i < 32) begin
            idle_cycle;
            i = i + 1;
        end
        chk(state_out == S_ACTIVE, 9, "2nd cycle: reached ACTIVE");
        chk(open_row  == test_row,  9, "2nd cycle: open_row updated");

        // Wait for tras_ok then issue PRE
        i = 0;
        while (!tras_ok && i < 64) begin
            idle_cycle;
            i = i + 1;
        end
        send_cmd(CMD_PRE, {ROW_ADDR_W{1'b0}});
        cmd_valid = 1'b0;
        chk(state_out == S_PRECHARGING, 9, "2nd cycle: PRECHARGING");

        // Wait for IDLE
        i = 0;
        while (state_out != S_IDLE && i < 32) begin
            idle_cycle;
            i = i + 1;
        end
        chk(state_out == S_IDLE, 9, "2nd cycle: back to IDLE");

        // ===========================================================
        // T10: open_row preserved across multiple RD/WR commands
        // ===========================================================
        test_row = 17'h12345;
        send_cmd(CMD_ACT, test_row);
        cmd_valid = 1'b0;

        i = 0;
        while (state_out != S_ACTIVE && i < 32) begin
            idle_cycle;
            i = i + 1;
        end

        repeat(4) begin
            send_cmd(CMD_RD, test_row);
            cmd_valid = 1'b0;
        end
        chk(open_row  == test_row,  10, "open_row stable across RD bursts");
        chk(state_out == S_ACTIVE,  10, "state ACTIVE across RD bursts");

        // ===========================================================
        // Summary
        // ===========================================================
        $display("--------------------------------------------");
        $display("bank_fsm_tb: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "bank_fsm_tb: simulation FAILED");
        $finish;
    end

endmodule
