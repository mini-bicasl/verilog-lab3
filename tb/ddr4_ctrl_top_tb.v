// ddr4_ctrl_top_tb.v – Integration testbench for ddr4_ctrl_top
//
// Uses compact timing parameters to keep simulation fast:
//   P_TRCD=4  P_TRP=4  P_TRAS=8  P_TRC=12
//   P_TCL=4  P_TCWL=3  P_TBURST=2
//   P_TREFI=120  P_TRFC=12
//
// Tests:
//   T1: Reset – AXI outputs quiet; awready/arready high after reset;
//       ddr4_reset_n low during reset, high after
//   T2: Write path – AXI write causes ACT then WR on the scheduler's
//       internal DRAM command bus; B-channel response OKAY with correct ID
//   T3: Read path – AXI read (fresh bank bg=1/bank=1) causes ACT then RD;
//       DRAM model provides ECC-clean data; R response returns correct data
//   T4: ECC double-bit error – wrong DM checkbits from DRAM → rresp=SLVERR
//   T5: Refresh – ref_req_i is asserted within tREFI cycles (confirms
//       refresh_ctrl countdown works; actual REF requires precharged banks)
//
// A background always block records when each DRAM command type appears on
// cmd_scheduler's dram_valid_i/dram_cmd_i so the initial block need not
// race against those signals.  Flags are cleared by the tb between tests.
//
// Compile & run (from repo root):
//   iverilog -g2012 -o build/ddr4_ctrl_top.out tb/ddr4_ctrl_top_tb.v \
//       rtl/ddr4_ctrl_top.v rtl/axi4_slave.v rtl/cmd_arbiter.v \
//       rtl/cmd_scheduler.v rtl/refresh_ctrl.v rtl/timing_ctrl.v \
//       rtl/bank_fsm.v rtl/ecc_encoder.v rtl/ecc_decoder.v rtl/phy_if.v
//   vvp build/ddr4_ctrl_top.out

`timescale 1ns/1ps

module ddr4_ctrl_top_tb;

    // ----------------------------------------------------------------
    // Compact timing parameters
    // ----------------------------------------------------------------
    localparam AXI_ADDR_W      = 34;
    localparam AXI_DATA_W      = 64;
    localparam AXI_ID_W        = 4;
    localparam RANKS           = 1;
    localparam BANK_GROUPS     = 4;
    localparam BANKS_PER_GROUP = 4;
    localparam ROW_ADDR_W      = 17;
    localparam COL_ADDR_W      = 10;

    localparam P_TRCD   = 4;
    localparam P_TRP    = 4;
    localparam P_TRAS   = 8;
    localparam P_TRC    = 12;
    localparam P_TRRD_S = 2;
    localparam P_TRRD_L = 3;
    localparam P_TCCD_S = 2;
    localparam P_TCCD_L = 3;
    localparam P_TFAW   = 10;
    localparam P_TWTR_S = 2;
    localparam P_TWTR_L = 4;
    localparam P_TRTP   = 4;
    localparam P_TWR    = 6;
    localparam P_TCL    = 4;
    localparam P_TCWL   = 3;
    localparam P_TBURST = 2;
    localparam P_TREFI  = 120;
    localparam P_TRFC   = 12;

    // Command encodings (match RTL)
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;

    // ----------------------------------------------------------------
    // Clock and reset
    // ----------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz / 10 ns period

    // ----------------------------------------------------------------
    // AXI4 signals
    // ----------------------------------------------------------------
    reg  [AXI_ID_W-1:0]       s_axi_awid;
    reg  [AXI_ADDR_W-1:0]     s_axi_awaddr;
    reg  [7:0]                 s_axi_awlen;
    reg  [2:0]                 s_axi_awsize;
    reg  [1:0]                 s_axi_awburst;
    reg                        s_axi_awvalid;
    wire                       s_axi_awready;

    reg  [AXI_DATA_W-1:0]     s_axi_wdata;
    reg  [(AXI_DATA_W/8)-1:0] s_axi_wstrb;
    reg                        s_axi_wlast;
    reg                        s_axi_wvalid;
    wire                       s_axi_wready;

    wire [AXI_ID_W-1:0]       s_axi_bid;
    wire [1:0]                 s_axi_bresp;
    wire                       s_axi_bvalid;
    reg                        s_axi_bready;

    reg  [AXI_ID_W-1:0]       s_axi_arid;
    reg  [AXI_ADDR_W-1:0]     s_axi_araddr;
    reg  [7:0]                 s_axi_arlen;
    reg  [2:0]                 s_axi_arsize;
    reg  [1:0]                 s_axi_arburst;
    reg                        s_axi_arvalid;
    wire                       s_axi_arready;

    wire [AXI_ID_W-1:0]       s_axi_rid;
    wire [AXI_DATA_W-1:0]     s_axi_rdata;
    wire [1:0]                 s_axi_rresp;
    wire                       s_axi_rlast;
    wire                       s_axi_rvalid;
    reg                        s_axi_rready;

    // ----------------------------------------------------------------
    // ECC / DDR4 pad wires
    // ----------------------------------------------------------------
    wire                       ecc_single_err;
    wire                       ecc_double_err;
    wire [AXI_ADDR_W-1:0]     ecc_err_addr;

    wire [RANKS-1:0]           ddr4_ck_p, ddr4_ck_n, ddr4_cke, ddr4_cs_n;
    wire                       ddr4_act_n, ddr4_ras_n, ddr4_cas_n, ddr4_we_n;
    wire [1:0]                 ddr4_ba, ddr4_bg;
    wire [ROW_ADDR_W-1:0]      ddr4_addr;
    wire [RANKS-1:0]           ddr4_odt;
    wire                       ddr4_reset_n;

    // Bidir buses
    reg  [63:0]                dram_dq_drive;
    reg  [7:0]                 dram_dm_drive;
    reg                        dram_bus_oe;
    reg  [7:0]                 dram_hold_cnt;

    wire [63:0]                ddr4_dq;
    wire [7:0]                 ddr4_dqs_p, ddr4_dqs_n;
    wire [7:0]                 ddr4_dm_dbi_n;

    assign ddr4_dq       = dram_bus_oe ? dram_dq_drive : 64'bz;
    assign ddr4_dm_dbi_n = dram_bus_oe ? dram_dm_drive :  8'bz;

    // Pre-loaded DRAM return values
    reg [63:0] dram_rd_data;
    reg [7:0]  dram_rd_dm;

    // ----------------------------------------------------------------
    // DUT
    // ----------------------------------------------------------------
    ddr4_ctrl_top #(
        .AXI_ADDR_W      (AXI_ADDR_W),
        .AXI_DATA_W      (AXI_DATA_W),
        .AXI_ID_W        (AXI_ID_W),
        .RANKS           (RANKS),
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
        .ROW_ADDR_W      (ROW_ADDR_W),
        .COL_ADDR_W      (COL_ADDR_W),
        .P_TRCD          (P_TRCD),
        .P_TRP           (P_TRP),
        .P_TRAS          (P_TRAS),
        .P_TRC           (P_TRC),
        .P_TRRD_S        (P_TRRD_S),
        .P_TRRD_L        (P_TRRD_L),
        .P_TCCD_S        (P_TCCD_S),
        .P_TCCD_L        (P_TCCD_L),
        .P_TFAW          (P_TFAW),
        .P_TWTR_S        (P_TWTR_S),
        .P_TWTR_L        (P_TWTR_L),
        .P_TRTP          (P_TRTP),
        .P_TWR           (P_TWR),
        .P_TCL           (P_TCL),
        .P_TCWL          (P_TCWL),
        .P_TBURST        (P_TBURST),
        .P_TREFI         (P_TREFI),
        .P_TRFC          (P_TRFC)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_axi_awid      (s_axi_awid),
        .s_axi_awaddr    (s_axi_awaddr),
        .s_axi_awlen     (s_axi_awlen),
        .s_axi_awsize    (s_axi_awsize),
        .s_axi_awburst   (s_axi_awburst),
        .s_axi_awvalid   (s_axi_awvalid),
        .s_axi_awready   (s_axi_awready),
        .s_axi_wdata     (s_axi_wdata),
        .s_axi_wstrb     (s_axi_wstrb),
        .s_axi_wlast     (s_axi_wlast),
        .s_axi_wvalid    (s_axi_wvalid),
        .s_axi_wready    (s_axi_wready),
        .s_axi_bid       (s_axi_bid),
        .s_axi_bresp     (s_axi_bresp),
        .s_axi_bvalid    (s_axi_bvalid),
        .s_axi_bready    (s_axi_bready),
        .s_axi_arid      (s_axi_arid),
        .s_axi_araddr    (s_axi_araddr),
        .s_axi_arlen     (s_axi_arlen),
        .s_axi_arsize    (s_axi_arsize),
        .s_axi_arburst   (s_axi_arburst),
        .s_axi_arvalid   (s_axi_arvalid),
        .s_axi_arready   (s_axi_arready),
        .s_axi_rid       (s_axi_rid),
        .s_axi_rdata     (s_axi_rdata),
        .s_axi_rresp     (s_axi_rresp),
        .s_axi_rlast     (s_axi_rlast),
        .s_axi_rvalid    (s_axi_rvalid),
        .s_axi_rready    (s_axi_rready),
        .ecc_single_err  (ecc_single_err),
        .ecc_double_err  (ecc_double_err),
        .ecc_err_addr    (ecc_err_addr),
        .ddr4_ck_p       (ddr4_ck_p),
        .ddr4_ck_n       (ddr4_ck_n),
        .ddr4_cke        (ddr4_cke),
        .ddr4_cs_n       (ddr4_cs_n),
        .ddr4_act_n      (ddr4_act_n),
        .ddr4_ras_n      (ddr4_ras_n),
        .ddr4_cas_n      (ddr4_cas_n),
        .ddr4_we_n       (ddr4_we_n),
        .ddr4_ba         (ddr4_ba),
        .ddr4_bg         (ddr4_bg),
        .ddr4_addr       (ddr4_addr),
        .ddr4_odt        (ddr4_odt),
        .ddr4_reset_n    (ddr4_reset_n),
        .ddr4_dq         (ddr4_dq),
        .ddr4_dqs_p      (ddr4_dqs_p),
        .ddr4_dqs_n      (ddr4_dqs_n),
        .ddr4_dm_dbi_n   (ddr4_dm_dbi_n)
    );

    // ----------------------------------------------------------------
    // VCD dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-top/ddr4_ctrl_top.vcd");
        $dumpvars(0, ddr4_ctrl_top_tb);
    end

    // ----------------------------------------------------------------
    // Watchdog
    // ----------------------------------------------------------------
    initial begin
        #60000;
        $display("WATCHDOG TIMEOUT");
        $fatal(1, "ddr4_ctrl_top_tb: watchdog fired");
    end

    // ----------------------------------------------------------------
    // DRAM read model
    //
    // Detects RD on cmd_scheduler's unregistered dram_valid_i/
    // dram_cmd_i (one cycle before DDR4 bus registers).  Starts
    // driving ddr4_dq on the following clock and holds for 7 cycles
    // so phy_if can capture at T+P_TCL.
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_bus_oe   <= 1'b0;
            dram_hold_cnt <= 8'd0;
        end else begin
            if (dut.dram_valid_i && (dut.dram_cmd_i == CMD_RD)) begin
                dram_dq_drive <= dram_rd_data;
                dram_dm_drive <= dram_rd_dm;
                dram_bus_oe   <= 1'b1;
                dram_hold_cnt <= 8'd7;
            end else if (dram_hold_cnt != 8'd0) begin
                dram_bus_oe   <= 1'b1;
                dram_hold_cnt <= dram_hold_cnt - 8'd1;
            end else begin
                dram_bus_oe   <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Background DRAM command monitors
    // Cleared by the TB setting mon_clear=1 for one cycle.
    // ----------------------------------------------------------------
    reg mon_clear;
    reg mon_act, mon_wr, mon_rd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || mon_clear) begin
            mon_act <= 1'b0;
            mon_wr  <= 1'b0;
            mon_rd  <= 1'b0;
        end else begin
            if (dut.dram_valid_i && dut.dram_cmd_i == CMD_ACT) mon_act <= 1'b1;
            if (dut.dram_valid_i && dut.dram_cmd_i == CMD_WR)  mon_wr  <= 1'b1;
            if (dut.dram_valid_i && dut.dram_cmd_i == CMD_RD)  mon_rd  <= 1'b1;
        end
    end

    // ----------------------------------------------------------------
    // AXI address helper
    //   addr[32:22] = row, [21:20] = bg, [19:18] = bank,
    //   [17:8] = col, [7:0] = byte offset
    // ----------------------------------------------------------------
    function [AXI_ADDR_W-1:0] mk_addr;
        input [1:0]  bg;
        input [1:0]  bank;
        input [10:0] row;
        input [9:0]  col;
        begin
            mk_addr = {1'b0, row, bg, bank, col, 8'b0};
        end
    endfunction

    // ----------------------------------------------------------------
    // ECC encoder (mirrors rtl/ecc_encoder.v)
    // ----------------------------------------------------------------
    function [7:0] ecc_chk;
        input [63:0] d;
        reg [6:0] c;
        reg ov;
        begin
            c[0] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[11]^
                   d[13]^d[15]^d[17]^d[19]^d[21]^d[23]^d[25]^d[26]^
                   d[28]^d[30]^d[32]^d[34]^d[36]^d[38]^d[40]^d[42]^
                   d[44]^d[46]^d[48]^d[50]^d[52]^d[54]^d[56]^d[57]^
                   d[59]^d[61]^d[63];
            c[1] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[10]^d[12]^
                   d[13]^d[16]^d[17]^d[20]^d[21]^d[24]^d[25]^d[27]^
                   d[28]^d[31]^d[32]^d[35]^d[36]^d[39]^d[40]^d[43]^
                   d[44]^d[47]^d[48]^d[51]^d[52]^d[55]^d[56]^d[58]^
                   d[59]^d[62]^d[63];
            c[2] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[10]^d[14]^
                   d[15]^d[16]^d[17]^d[22]^d[23]^d[24]^d[25]^d[29]^
                   d[30]^d[31]^d[32]^d[37]^d[38]^d[39]^d[40]^d[45]^
                   d[46]^d[47]^d[48]^d[53]^d[54]^d[55]^d[56]^d[60]^
                   d[61]^d[62]^d[63];
            c[3] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[10]^d[18]^
                   d[19]^d[20]^d[21]^d[22]^d[23]^d[24]^d[25]^d[33]^
                   d[34]^d[35]^d[36]^d[37]^d[38]^d[39]^d[40]^d[49]^
                   d[50]^d[51]^d[52]^d[53]^d[54]^d[55]^d[56];
            c[4] = d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^
                   d[19]^d[20]^d[21]^d[22]^d[23]^d[24]^d[25]^d[41]^
                   d[42]^d[43]^d[44]^d[45]^d[46]^d[47]^d[48]^d[49]^
                   d[50]^d[51]^d[52]^d[53]^d[54]^d[55]^d[56];
            c[5] = d[26]^d[27]^d[28]^d[29]^d[30]^d[31]^d[32]^d[33]^
                   d[34]^d[35]^d[36]^d[37]^d[38]^d[39]^d[40]^d[41]^
                   d[42]^d[43]^d[44]^d[45]^d[46]^d[47]^d[48]^d[49]^
                   d[50]^d[51]^d[52]^d[53]^d[54]^d[55]^d[56];
            c[6] = d[57]^d[58]^d[59]^d[60]^d[61]^d[62]^d[63];
            ov   = ^d ^ ^c;
            ecc_chk = {ov, c};
        end
    endfunction

    // ----------------------------------------------------------------
    // Pass/fail bookkeeping
    // ----------------------------------------------------------------
    integer pass_count, fail_count;

    task chk;
        input        cond;
        input [31:0] tid;
        input [127:0] msg;
        begin
            if (cond) begin
                $display("PASS T%0d: %s", tid, msg);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL T%0d: %s", tid, msg);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Helper tasks (negedge-setup / posedge-sample)
    // ----------------------------------------------------------------

    task drive_aw;
        input [AXI_ID_W-1:0]   id;
        input [AXI_ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            s_axi_awid    = id;
            s_axi_awaddr  = addr;
            s_axi_awlen   = 8'd0;
            s_axi_awsize  = 3'd3;
            s_axi_awburst = 2'b01;
            s_axi_awvalid = 1'b1;
            @(posedge clk); #1;
            s_axi_awvalid = 1'b0;
        end
    endtask

    task drive_w;
        input [AXI_DATA_W-1:0] data;
        begin
            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = {(AXI_DATA_W/8){1'b1}};
            s_axi_wlast  = 1'b1;
            s_axi_wvalid = 1'b1;
            @(posedge clk); #1;
            s_axi_wvalid = 1'b0;
            s_axi_wlast  = 1'b0;
        end
    endtask

    task drive_ar;
        input [AXI_ID_W-1:0]   id;
        input [AXI_ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            s_axi_arid    = id;
            s_axi_araddr  = addr;
            s_axi_arlen   = 8'd0;
            s_axi_arsize  = 3'd3;
            s_axi_arburst = 2'b01;
            s_axi_arvalid = 1'b1;
            @(posedge clk); #1;
            s_axi_arvalid = 1'b0;
        end
    endtask

    // Captured AXI read response
    reg [AXI_DATA_W-1:0] cap_rdata;
    reg [1:0]            cap_rresp;
    reg [AXI_ID_W-1:0]  cap_rid;

    // Wait for R response (up to 50 cycles)
    task wait_r_resp;
        integer tc_r;
        begin
            s_axi_rready = 1'b1;
            tc_r = 0;
            @(posedge clk); #1;
            while (!s_axi_rvalid && tc_r < 50) begin
                @(posedge clk); #1;
                tc_r = tc_r + 1;
            end
            cap_rdata = s_axi_rdata;
            cap_rresp = s_axi_rresp;
            cap_rid   = s_axi_rid;
            @(posedge clk); #1;
            s_axi_rready = 1'b0;
        end
    endtask

    // ================================================================
    // Main test sequencer
    // ================================================================
    integer t_loop;
    reg     seen_bvalid;
    reg [AXI_ID_W-1:0] cap_bid;
    reg [1:0]          cap_bresp;

    initial begin
        pass_count  = 0;
        fail_count  = 0;
        mon_clear   = 1'b0;

        // Default stimulus
        rst_n         = 1'b0;
        s_axi_awid    = {AXI_ID_W{1'b0}};
        s_axi_awaddr  = {AXI_ADDR_W{1'b0}};
        s_axi_awlen   = 8'd0;
        s_axi_awsize  = 3'd3;
        s_axi_awburst = 2'b01;
        s_axi_awvalid = 1'b0;
        s_axi_wdata   = {AXI_DATA_W{1'b0}};
        s_axi_wstrb   = {(AXI_DATA_W/8){1'b1}};
        s_axi_wlast   = 1'b0;
        s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_arid    = {AXI_ID_W{1'b0}};
        s_axi_araddr  = {AXI_ADDR_W{1'b0}};
        s_axi_arlen   = 8'd0;
        s_axi_arsize  = 3'd3;
        s_axi_arburst = 2'b01;
        s_axi_arvalid = 1'b0;
        s_axi_rready  = 1'b0;
        dram_rd_data  = 64'h0;
        dram_rd_dm    =  8'h0;

        // ============================================================
        // T1: Reset state
        // ============================================================
        repeat(4) @(posedge clk); #1;
        chk(s_axi_bvalid  == 1'b0, 1, "reset: bvalid=0");
        chk(s_axi_rvalid  == 1'b0, 1, "reset: rvalid=0");
        chk(ddr4_reset_n  == 1'b0, 1, "ddr4_reset_n=0");

        rst_n = 1'b1;
        @(posedge clk); #1;
        chk(s_axi_awready == 1'b1, 1, "awready=1");
        chk(s_axi_arready == 1'b1, 1, "arready=1");
        chk(ddr4_reset_n  == 1'b1, 1, "ddr4_reset_n=1");
        chk(ddr4_cke      == 1'b1, 1, "cke=1");

        // ============================================================
        // T2: Write path (bg=0 bank=0 row=1 col=1)
        // ============================================================
        // Clear monitors
        @(negedge clk); mon_clear = 1'b1;
        @(posedge clk); #1; mon_clear = 1'b0;

        seen_bvalid = 1'b0;
        cap_bid     = {AXI_ID_W{1'b0}};
        cap_bresp   = 2'b00;

        drive_aw(4'h1, mk_addr(2'b00, 2'b00, 11'h001, 10'h001));
        drive_w(64'hDEAD_BEEF_CAFE_F00D);

        // Accept B response; keep bready high during command monitoring
        s_axi_bready = 1'b1;

        // Wait up to 50 cycles for ACT+WR+B
        for (t_loop = 0; t_loop < 50; t_loop = t_loop + 1) begin
            @(posedge clk); #1;
            if (s_axi_bvalid && !seen_bvalid) begin
                seen_bvalid = 1'b1;
                cap_bid     = s_axi_bid;
                cap_bresp   = s_axi_bresp;
            end
            if (seen_bvalid && mon_act && mon_wr) t_loop = 50;
        end
        s_axi_bready = 1'b0;
        @(posedge clk); #1;

        chk(mon_act     == 1'b1,  2, "write: ACT issued");
        chk(mon_wr      == 1'b1,  2, "write: WR issued");
        chk(seen_bvalid == 1'b1,  2, "write: bvalid");
        chk(cap_bid     == 4'h1,  2, "write: bid=1");
        chk(cap_bresp   == 2'b00, 2, "write: OKAY");

        // ============================================================
        // T3: Read path (fresh bank: bg=1 bank=1)
        // ============================================================
        // Clear monitors
        @(negedge clk); mon_clear = 1'b1;
        @(posedge clk); #1; mon_clear = 1'b0;

        dram_rd_data = 64'h1234_5678_9ABC_DEF0;
        dram_rd_dm   = ecc_chk(64'h1234_5678_9ABC_DEF0);

        drive_ar(4'h2, mk_addr(2'b01, 2'b01, 11'h010, 10'h001));
        wait_r_resp;

        chk(mon_rd    == 1'b1,                   3, "read: RD issued");
        chk(cap_rid   == 4'h2,                   3, "read: rid=2");
        chk(cap_rdata == 64'h1234_5678_9ABC_DEF0, 3, "read: rdata correct");
        chk(cap_rresp == 2'b00,                  3, "read: OKAY");

        @(posedge clk); #1;

        // ============================================================
        // T4: ECC double-bit error (fresh bank: bg=2 bank=2)
        //   Inject wrong checkbits → dec_double_err=1 → SLVERR
        // ============================================================
        dram_rd_data = 64'hFFFF_FFFF_FFFF_FFFF;
        dram_rd_dm   = 8'hAA;  // wrong checkbits

        drive_ar(4'h3, mk_addr(2'b10, 2'b10, 11'h020, 10'h001));
        wait_r_resp;

        chk(cap_rresp == 2'b10, 4, "ecc-dbe: SLVERR");
        chk(cap_rid   == 4'h3,  4, "ecc-dbe: rid=3");

        @(posedge clk); #1;

        // ============================================================
        // T5: Refresh pending (ref_req asserted after tREFI=120 cycles)
        // ============================================================
        begin
            integer ref_wait;
            ref_wait = 0;
            @(posedge clk); #1;
            while (!dut.ref_req_i && ref_wait < 200) begin
                @(posedge clk); #1;
                ref_wait = ref_wait + 1;
            end
            chk(dut.ref_req_i == 1'b1, 5, "refresh: ref_req fires");
        end

        // ============================================================
        // Summary
        // ============================================================
        $display("--------------------------------------------");
        $display("ddr4_ctrl_top_tb: %0d PASSED, %0d FAILED",
                 pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "ddr4_ctrl_top_tb: simulation FAILED");
        $finish;
    end

endmodule
