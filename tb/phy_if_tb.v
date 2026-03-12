// phy_if_tb.v – Testbench for phy_if (DDR4 PHY interface)
//
// Compact timing parameters keep the simulation fast:
//   P_TCL    =  5   CAS latency (controller clocks)
//   P_TCWL   =  4   CAS write latency (controller clocks, >= 2)
//   P_TBURST =  4   Write burst duration (BL8 / 2 = 4 controller clocks)
//
// Tests:
//   T1 : Reset state – command bus NOP, DQ/DQS Hi-Z, wl_done=0
//   T2 : Command bus – ACT, RD, WR, PRE, REF map to correct DDR4 encodings
//   T3 : DQ direction (write) – DQ driven after WR command + CWL delay
//   T4 : DQS preamble – DQS_p=0 for 1 cycle before first DQS toggle
//   T5 : DQS burst – DQS_p toggles P_TBURST clocks during write burst
//   T6 : DQS postamble – DQS_p=0 for 1 cycle after last toggle
//   T7 : DQ direction (read) – DQ bus is Hi-Z after RD command
//   T8 : Read data capture – rd_dq latched P_TCL clocks after RD command
//   T9 : Write-leveling – wl_done asserts after WL_CALIB_CYCLES clocks
//  T10 : Init gate – cs_n deasserted only when init_done=1
//
// Compile & run:
//   iverilog -g2012 -o build/phy_if.out tb/phy_if_tb.v rtl/phy_if.v
//   vvp build/phy_if.out

`timescale 1ns/1ps

module phy_if_tb;

    // ----------------------------------------------------------------
    // DUT parameters (compact values for simulation speed)
    // ----------------------------------------------------------------
    localparam RANKS      = 1;
    localparam DQ_WIDTH   = 64;
    localparam DQS_WIDTH  = 8;
    localparam DM_WIDTH   = 8;
    localparam ROW_ADDR_W = 17;
    localparam COL_ADDR_W = 10;
    localparam P_TCL      = 5;
    localparam P_TCWL     = 4;
    localparam P_TBURST   = 4;
    localparam WL_CALIB_CYCLES = 8; // must match RTL localparam

    // ----------------------------------------------------------------
    // Clock and reset
    // ----------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz / 10 ns period

    // ----------------------------------------------------------------
    // DUT inputs
    // ----------------------------------------------------------------
    reg [2:0]              ctrl_cmd;
    reg [1:0]              ctrl_bg;
    reg [1:0]              ctrl_ba;
    reg [ROW_ADDR_W-1:0]   ctrl_addr;
    reg                    ctrl_cmd_valid;

    reg [DQ_WIDTH-1:0]     wr_dq;
    reg [DM_WIDTH-1:0]     wr_dm;
    reg                    wr_data_valid;

    reg                    wl_mode;
    reg                    init_done;

    // ----------------------------------------------------------------
    // DUT outputs
    // ----------------------------------------------------------------
    wire [DQ_WIDTH-1:0]    rd_dq;
    wire [DM_WIDTH-1:0]    rd_dm;
    wire                   rd_data_valid;
    wire                   wl_done;
    wire                   dq_oe;
    wire                   dqs_oe;

    wire [RANKS-1:0]       ddr4_ck_p;
    wire [RANKS-1:0]       ddr4_ck_n;
    wire [RANKS-1:0]       ddr4_cke;
    wire [RANKS-1:0]       ddr4_cs_n;
    wire                   ddr4_act_n;
    wire                   ddr4_ras_n;
    wire                   ddr4_cas_n;
    wire                   ddr4_we_n;
    wire [1:0]             ddr4_ba;
    wire [1:0]             ddr4_bg;
    wire [ROW_ADDR_W-1:0]  ddr4_addr;
    wire [RANKS-1:0]       ddr4_odt;
    wire                   ddr4_reset_n;

    // ----------------------------------------------------------------
    // Bidir bus drivers (simulate DRAM side for reads)
    // ----------------------------------------------------------------
    reg  [DQ_WIDTH-1:0]    dram_dq_drive;
    reg  [DM_WIDTH-1:0]    dram_dm_drive;
    reg                    dram_bus_oe;    // DRAM drives bus when 1

    wire [DQ_WIDTH-1:0]    ddr4_dq;
    wire [DQS_WIDTH-1:0]   ddr4_dqs_p;
    wire [DQS_WIDTH-1:0]   ddr4_dqs_n;
    wire [DM_WIDTH-1:0]    ddr4_dm_dbi_n;

    // TB drives DQ/DM when simulating DRAM read data
    assign ddr4_dq      = dram_bus_oe ? dram_dq_drive : {DQ_WIDTH{1'bz}};
    assign ddr4_dm_dbi_n= dram_bus_oe ? dram_dm_drive : {DM_WIDTH{1'bz}};

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    phy_if #(
        .RANKS      (RANKS),
        .DQ_WIDTH   (DQ_WIDTH),
        .DQS_WIDTH  (DQS_WIDTH),
        .DM_WIDTH   (DM_WIDTH),
        .ROW_ADDR_W (ROW_ADDR_W),
        .COL_ADDR_W (COL_ADDR_W),
        .P_TCL      (P_TCL),
        .P_TCWL     (P_TCWL),
        .P_TBURST   (P_TBURST)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .ctrl_cmd       (ctrl_cmd),
        .ctrl_bg        (ctrl_bg),
        .ctrl_ba        (ctrl_ba),
        .ctrl_addr      (ctrl_addr),
        .ctrl_cmd_valid (ctrl_cmd_valid),
        .wr_dq          (wr_dq),
        .wr_dm          (wr_dm),
        .wr_data_valid  (wr_data_valid),
        .rd_dq          (rd_dq),
        .rd_dm          (rd_dm),
        .rd_data_valid  (rd_data_valid),
        .wl_mode        (wl_mode),
        .wl_done        (wl_done),
        .init_done      (init_done),
        .dq_oe          (dq_oe),
        .dqs_oe         (dqs_oe),
        .ddr4_ck_p      (ddr4_ck_p),
        .ddr4_ck_n      (ddr4_ck_n),
        .ddr4_cke       (ddr4_cke),
        .ddr4_cs_n      (ddr4_cs_n),
        .ddr4_act_n     (ddr4_act_n),
        .ddr4_ras_n     (ddr4_ras_n),
        .ddr4_cas_n     (ddr4_cas_n),
        .ddr4_we_n      (ddr4_we_n),
        .ddr4_ba        (ddr4_ba),
        .ddr4_bg        (ddr4_bg),
        .ddr4_addr      (ddr4_addr),
        .ddr4_odt       (ddr4_odt),
        .ddr4_reset_n   (ddr4_reset_n),
        .ddr4_dq        (ddr4_dq),
        .ddr4_dqs_p     (ddr4_dqs_p),
        .ddr4_dqs_n     (ddr4_dqs_n),
        .ddr4_dm_dbi_n  (ddr4_dm_dbi_n)
    );

    // ----------------------------------------------------------------
    // Command encodings (mirror RTL)
    // ----------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // ----------------------------------------------------------------
    // Waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-phy/phy_if.vcd");
        $dumpvars(0, phy_if_tb);
    end

    // ----------------------------------------------------------------
    // Check helper
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
                $display("FAIL T%0d: %s", test_id, msg);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Clock helpers
    // ----------------------------------------------------------------
    task clk_cycle;
        begin
            @(negedge clk);
            ctrl_cmd_valid  = 1'b0;
            ctrl_cmd        = CMD_NOP;
            wr_data_valid   = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    task send_cmd;
        input [2:0]            c;
        input [1:0]            bg;
        input [1:0]            ba;
        input [ROW_ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            ctrl_cmd       = c;
            ctrl_bg        = bg;
            ctrl_ba        = ba;
            ctrl_addr      = addr;
            ctrl_cmd_valid = 1'b1;
            @(posedge clk); #1;
            ctrl_cmd_valid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Main test sequencer
    // ----------------------------------------------------------------
    integer i;
    integer dqs_low_before, dqs_high, dqs_low_after;
    reg [DQ_WIDTH-1:0] test_dq_data;
    reg [DM_WIDTH-1:0] test_dm_data;

    initial begin
        pass_count    = 0;
        fail_count    = 0;

        // Initialise TB stimulus
        ctrl_cmd       = CMD_NOP;
        ctrl_bg        = 2'b00;
        ctrl_ba        = 2'b00;
        ctrl_addr      = {ROW_ADDR_W{1'b0}};
        ctrl_cmd_valid = 1'b0;
        wr_dq          = {DQ_WIDTH{1'b0}};
        wr_dm          = {DM_WIDTH{1'b0}};
        wr_data_valid  = 1'b0;
        wl_mode        = 1'b0;
        init_done      = 1'b0;
        dram_dq_drive  = {DQ_WIDTH{1'b0}};
        dram_dm_drive  = {DM_WIDTH{1'b0}};
        dram_bus_oe    = 1'b0;

        // ===========================================================
        // T1: Reset state
        // ===========================================================
        rst_n = 1'b0;
        repeat(4) @(posedge clk); #1;

        chk(ddr4_act_n    == 1'b1,           1, "reset: act_n=1 (NOP)");
        chk(ddr4_ras_n    == 1'b1,           1, "reset: ras_n=1 (NOP)");
        chk(ddr4_cas_n    == 1'b1,           1, "reset: cas_n=1 (NOP)");
        chk(ddr4_we_n     == 1'b1,           1, "reset: we_n=1 (NOP)");
        chk(dq_oe         == 1'b0,           1, "reset: dq_oe=0 (Hi-Z)");
        chk(dqs_oe        == 1'b0,           1, "reset: dqs_oe=0 (Hi-Z)");
        chk(wl_done       == 1'b0,           1, "reset: wl_done=0");
        // Verify DQ bus is actually Hi-Z during reset
        chk(ddr4_dq       === {DQ_WIDTH{1'bz}}, 1, "reset: DQ=Hi-Z");
        chk(ddr4_dqs_p    === {DQS_WIDTH{1'bz}},1, "reset: DQS_p=Hi-Z");

        rst_n = 1'b1;
        init_done = 1'b1;    // init complete for subsequent tests
        @(posedge clk); #1;

        // ===========================================================
        // T2: Command bus encodings
        //
        // The command bus is registered: outputs become visible at the
        // posedge where ctrl_cmd_valid is asserted.  send_cmd() returns
        // immediately after that posedge (#1), so we check the encoded
        // values BEFORE calling clk_cycle (which would issue a NOP and
        // overwrite the registered output on the very next clock).
        // ===========================================================
        // ACT: act_n=0
        send_cmd(CMD_ACT, 2'b01, 2'b10, 17'h1CAFE);
        chk(ddr4_act_n == 1'b0, 2, "ACT: act_n=0");
        chk(ddr4_ba    == 2'b10, 2, "ACT: ba latched");
        chk(ddr4_bg    == 2'b01, 2, "ACT: bg latched");

        // RD: act_n=1, cas_n=0, we_n=1
        send_cmd(CMD_RD, 2'b00, 2'b00, 17'h0_0100);
        chk(ddr4_act_n == 1'b1, 2, "RD: act_n=1");
        chk(ddr4_cas_n == 1'b0, 2, "RD: cas_n=0");
        chk(ddr4_we_n  == 1'b1, 2, "RD: we_n=1");

        // WR: act_n=1, cas_n=0, we_n=0
        // (also starts a write burst in the background; drained below)
        send_cmd(CMD_WR, 2'b00, 2'b00, 17'h0_0200);
        chk(ddr4_act_n == 1'b1, 2, "WR: act_n=1");
        chk(ddr4_cas_n == 1'b0, 2, "WR: cas_n=0");
        chk(ddr4_we_n  == 1'b0, 2, "WR: we_n=0");

        // PRE: act_n=1, ras_n=0, cas_n=1, we_n=0
        send_cmd(CMD_PRE, 2'b00, 2'b00, 17'h0);
        chk(ddr4_act_n == 1'b1, 2, "PRE: act_n=1");
        chk(ddr4_ras_n == 1'b0, 2, "PRE: ras_n=0");
        chk(ddr4_cas_n == 1'b1, 2, "PRE: cas_n=1");
        chk(ddr4_we_n  == 1'b0, 2, "PRE: we_n=0");

        // REF: act_n=1, ras_n=0, cas_n=0, we_n=1
        send_cmd(CMD_REF, 2'b00, 2'b00, 17'h0);
        chk(ddr4_act_n == 1'b1, 2, "REF: act_n=1");
        chk(ddr4_ras_n == 1'b0, 2, "REF: ras_n=0");
        chk(ddr4_cas_n == 1'b0, 2, "REF: cas_n=0");
        chk(ddr4_we_n  == 1'b1, 2, "REF: we_n=1");

        // After issuing NOP, verify command bus returns to NOP state
        clk_cycle;
        chk(ddr4_act_n == 1'b1, 2, "NOP: act_n=1");
        chk(ddr4_ras_n == 1'b1, 2, "NOP: ras_n=1");
        chk(ddr4_cas_n == 1'b1, 2, "NOP: cas_n=1");
        chk(ddr4_we_n  == 1'b1, 2, "NOP: we_n=1");

        // Drain the write burst started by T2's CMD_WR before T3.
        // Burst completes in P_TCWL + 1(PRE) + P_TBURST + 1(POST) = 10 clocks
        // from the CMD_WR.  The CMD_WR was 2 commands ago; add margin.
        repeat(P_TCWL + P_TBURST + 4) begin
            clk_cycle;
        end

        // ===========================================================
        // T3–T6: Write path – DQ direction, preamble, burst, postamble
        //
        //  Issue WR command with write data simultaneously.
        //  Timeline (P_TCWL=4, P_TBURST=4), all times relative to T_wr:
        //
        //    T_wr       : WR cmd sampled; WR_IDLE→WR_CWL, wr_cnt=P_TCWL-2=2
        //    T_wr+1..+3 : WR_CWL countdown (cnt: 2→1→0→WR_PRE)
        //    T_wr+4     : WR_PRE runs; registers dq_oe=1, dqs_p=0, cnt=3, →WR_DATA
        //    T_wr+4+1ns : preamble VISIBLE: dq_oe=1, dqs_p=0
        //    T_wr+5+1ns : WR_DATA[0]: dqs_p=1 (first toggle)
        //    T_wr+6+1ns : WR_DATA[1]: dqs_p=0
        //    T_wr+7+1ns : WR_DATA[2]: dqs_p=1
        //    T_wr+8+1ns : WR_DATA[3] last (cnt=0→WR_POST): dqs_p=0 (postamble)
        //    T_wr+9+1ns : WR_POST ran: dq_oe=0, dqs_oe=0 → Hi-Z
        //
        //  We use repeat(P_TCWL) clk_cycles (not P_TCWL-1) because WR_PRE
        //  assignments are registered and become visible ONE clock after
        //  WR_PRE is the active state.
        // ===========================================================
        test_dq_data = 64'hDEAD_BEEF_CAFE_1234;
        test_dm_data = 8'hA5;

        // Latch write data and issue WR on the same clock
        @(negedge clk);
        ctrl_cmd       = CMD_WR;
        ctrl_bg        = 2'b00;
        ctrl_ba        = 2'b01;
        ctrl_addr      = 17'h0_0400;
        ctrl_cmd_valid = 1'b1;
        wr_dq          = test_dq_data;
        wr_dm          = test_dm_data;
        wr_data_valid  = 1'b1;
        @(posedge clk); #1;
        ctrl_cmd_valid = 1'b0;
        wr_data_valid  = 1'b0;

        // T3: DQ should still be Hi-Z right after WR command (CWL delay)
        chk(dq_oe  == 1'b0, 3, "after WR cmd: dq_oe still 0 (CWL not expired)");
        chk(dqs_oe == 1'b0, 3, "after WR cmd: dqs_oe still 0 (CWL not expired)");

        // Wait P_TCWL cycles: WR_CWL runs (P_TCWL-1 cycles to reach WR_PRE)
        // then WR_PRE runs (1 cycle), making its registered outputs visible.
        repeat(P_TCWL) begin
            clk_cycle;
        end
        // Now at T_wr + P_TCWL + 1ns: WR_PRE has run; dq_oe=1, dqs_p=0 visible
        chk(dq_oe  == 1'b1, 3, "after CWL+PRE: dq_oe=1 (DQ driving)");
        chk(dqs_oe == 1'b1, 3, "after CWL+PRE: dqs_oe=1 (DQS driving)");
        // Verify DQ bus is no longer Hi-Z
        chk(ddr4_dq !== {DQ_WIDTH{1'bz}}, 3, "DQ bus driven (not Hi-Z) during write");

        // ---- T4: Preamble ----
        // dqs_p_out_r was loaded with 0 in WR_PRE and is now visible.
        chk(ddr4_dqs_p[0] === 1'b0, 4, "preamble: DQS_p[0]=0 (pre-amble low)");
        chk(ddr4_dqs_n[0] === 1'b1, 4, "preamble: DQS_n[0]=1 (differential)");
        dqs_low_before = (ddr4_dqs_p === {DQS_WIDTH{1'b0}}) ? 1 : 0;

        // Step one clock; WR_DATA[0] toggles dqs_p → 1
        clk_cycle;

        // ---- T5: First DQS toggle during burst ----
        chk(ddr4_dqs_p[0] === 1'b1, 5, "burst cy0: DQS_p[0]=1 (first toggle)");
        dqs_high = (ddr4_dqs_p[0] === 1'b1) ? 1 : 0;

        // Step through remaining burst clocks collecting DQS_p pattern
        // Burst cy1: DQS_p=0  cy2: DQS_p=1  cy3: DQS_p=0 → last state (seen in WR_POST)
        clk_cycle; chk(ddr4_dqs_p[0]===1'b0, 5, "burst cy1: DQS_p[0]=0");
        clk_cycle; chk(ddr4_dqs_p[0]===1'b1, 5, "burst cy2: DQS_p[0]=1");
        clk_cycle; // burst cy3: DQS_p visible=0 (WR_DATA last toggle),
                   // state→WR_POST in next clock

        // ---- T6: Postamble ----
        // WR_POST is now the state; dqs_p_out_r = 0 (from final toggle)
        chk(ddr4_dqs_p[0] === 1'b0, 6, "postamble: DQS_p[0]=0 (post-amble low)");
        chk(ddr4_dqs_n[0] === 1'b1, 6, "postamble: DQS_n[0]=1 (differential)");
        dqs_low_after = (ddr4_dqs_p === {DQS_WIDTH{1'b0}}) ? 1 : 0;
        chk(dqs_low_before && dqs_high && dqs_low_after, 6,
            "DQS sequence: low(pre) - toggle(burst) - low(post)");

        // One more clock: WR_IDLE, DQ/DQS released
        clk_cycle;
        chk(dq_oe  == 1'b0, 6, "after postamble: dq_oe=0 (Hi-Z)");
        chk(dqs_oe == 1'b0, 6, "after postamble: dqs_oe=0 (Hi-Z)");
        chk(ddr4_dq    === {DQ_WIDTH{1'bz}},  6, "DQ bus Hi-Z after write");
        chk(ddr4_dqs_p === {DQS_WIDTH{1'bz}}, 6, "DQS_p Hi-Z after write");

        // ===========================================================
        // T7: DQ direction during read – bus must be Hi-Z
        // ===========================================================
        send_cmd(CMD_RD, 2'b00, 2'b00, 17'h0_0080);

        // While counting down CL latency, verify DQ remains Hi-Z
        repeat(P_TCL - 1) begin
            clk_cycle;
            chk(dq_oe == 1'b0, 7, "RD in progress: dq_oe=0 (DQ Hi-Z)");
        end

        // ===========================================================
        // T8: Read data capture
        //   The TB drives a known pattern onto the DQ bus to simulate
        //   the DRAM supplying read data.
        // ===========================================================
        test_dq_data = 64'hFEED_FACE_DEAD_BEEF;
        test_dm_data = 8'h3C;

        dram_dq_drive = test_dq_data;
        dram_dm_drive = test_dm_data;
        dram_bus_oe   = 1'b1;   // DRAM drives the bus

        // The capture happens when rd_cnt reaches 0 (rd_armed cycle)
        // We're currently at T+P_TCL-1 from the RD command.
        // Wait 1 more cycle for the capture to happen.
        clk_cycle;

        // rd_data_valid should pulse this cycle
        chk(rd_data_valid  == 1'b1,           8, "read capture: rd_data_valid=1");
        chk(rd_dq          == test_dq_data,    8, "read capture: rd_dq matches DRAM data");
        chk(rd_dm          == test_dm_data,    8, "read capture: rd_dm matches DRAM DM");

        dram_bus_oe = 1'b0;   // Release DRAM bus drive

        clk_cycle;
        chk(rd_data_valid == 1'b0, 8, "read: rd_data_valid de-asserted after pulse");

        // ===========================================================
        // T9: Write-leveling calibration
        // ===========================================================
        wl_mode = 1'b1;

        // DQS should be driven during WL (wl_done not yet asserted)
        @(posedge clk); #1;
        chk(dqs_oe == 1'b1, 9, "WL mode: dqs_oe=1 (DQS driven for leveling)");
        chk(wl_done == 1'b0, 9, "WL mode: wl_done=0 initially");

        // Wait for wl_done (WL_CALIB_CYCLES clocks)
        i = 0;
        while (!wl_done && i < WL_CALIB_CYCLES + 4) begin
            @(posedge clk); #1;
            i = i + 1;
        end
        chk(wl_done == 1'b1, 9, "WL mode: wl_done=1 after calibration");

        // De-assert wl_mode; wl_done should clear
        wl_mode = 1'b0;
        @(posedge clk); #1;
        chk(wl_done == 1'b0, 9, "WL mode off: wl_done=0 after wl_mode deasserted");
        chk(dqs_oe  == 1'b0, 9, "WL mode off: dqs_oe=0");

        // ===========================================================
        // T10: Init gate (CS_n / CKE)
        // ===========================================================
        // Drive reset and clear init_done to test CS_n
        rst_n     = 1'b0;
        init_done = 1'b0;
        @(posedge clk); #1;
        chk(ddr4_cs_n[0]  == 1'b1, 10, "reset+no-init: cs_n=1 (DRAM deselected)");
        chk(ddr4_cke[0]   == 1'b0, 10, "reset+no-init: cke=0");
        chk(ddr4_reset_n  == 1'b0, 10, "reset: ddr4_reset_n follows rst_n");

        rst_n     = 1'b1;
        init_done = 1'b0;
        @(posedge clk); #1;
        chk(ddr4_cs_n[0] == 1'b1, 10, "rst_n=1 no-init: cs_n=1 (init_done=0)");

        init_done = 1'b1;
        @(posedge clk); #1;
        chk(ddr4_cs_n[0] == 1'b0, 10, "init_done=1: cs_n=0 (DRAM selected)");
        chk(ddr4_cke[0]  == 1'b1, 10, "init_done=1: cke=1");

        // ===========================================================
        // Summary
        // ===========================================================
        $display("--------------------------------------------");
        $display("phy_if_tb: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "phy_if_tb: simulation FAILED");
        $finish;
    end

endmodule
