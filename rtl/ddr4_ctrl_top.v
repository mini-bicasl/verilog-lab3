// ddr4_ctrl_top.v – DDR4 Controller Top-Level Integration
//
// Ties together all sub-modules:
//   axi4_slave   – AXI4 subordinate interface
//   cmd_arbiter  – read/write priority arbiter
//   cmd_scheduler – DRAM command sequencer (ACT/RD/WR/PRE)
//   refresh_ctrl  – REFab/REFpb refresh controller
//   timing_ctrl   – JEDEC timing constraint enforcer
//   bank_fsm      – 16× per-bank FSM (BANK_GROUPS × BANKS_PER_GROUP)
//   ecc_encoder   – SECDED(72,64) check-bit generator (write path)
//   ecc_decoder   – SECDED(72,64) error corrector (read path)
//   phy_if        – DDR4 PHY bidir pad interface
//
// Data flow (write):
//   AXI WDATA → ecc_encoder → phy_if (wr_dq + wr_dm) → ddr4_dq/dm_dbi_n
//
// Data flow (read):
//   ddr4_dq/dm_dbi_n → phy_if (rd_dq + rd_dm) → ecc_decoder → AXI RDATA
//
// Address decode is performed inside cmd_scheduler per docs/ARCHITECTURE.md §7.
//
// Reset: active-low asynchronous (all sub-modules share rst_n).
//
// Compile & run:
//   iverilog -g2012 -o build/ddr4_ctrl_top.out tb/ddr4_ctrl_top_tb.v \
//       rtl/ddr4_ctrl_top.v rtl/axi4_slave.v rtl/cmd_arbiter.v \
//       rtl/cmd_scheduler.v rtl/refresh_ctrl.v rtl/timing_ctrl.v \
//       rtl/bank_fsm.v rtl/ecc_encoder.v rtl/ecc_decoder.v rtl/phy_if.v
//   vvp build/ddr4_ctrl_top.out

`default_nettype none

module ddr4_ctrl_top #(
    // AXI4 parameters
    parameter AXI_ADDR_W      = 34,
    parameter AXI_DATA_W      = 64,
    parameter AXI_ID_W        = 8,
    // DRAM topology
    parameter RANKS           = 1,
    parameter BANK_GROUPS     = 4,
    parameter BANKS_PER_GROUP = 4,
    parameter ROW_ADDR_W      = 17,
    parameter COL_ADDR_W      = 10,
    // Clock period (ps) – informational only
    parameter TCK_PS          = 625,
    // Timing parameters (clock cycles, DDR4-3200 defaults)
    parameter P_TRCD          = 14,
    parameter P_TRP           = 14,
    parameter P_TRAS          = 52,
    parameter P_TRC           = 66,
    parameter P_TRRD_S        = 4,
    parameter P_TRRD_L        = 6,
    parameter P_TCCD_S        = 4,
    parameter P_TCCD_L        = 6,
    parameter P_TFAW          = 40,
    parameter P_TWTR_S        = 4,
    parameter P_TWTR_L        = 12,
    parameter P_TRTP          = 12,
    parameter P_TWR           = 24,
    // PHY timing
    parameter P_TCL           = 11,   // CAS latency
    parameter P_TCWL          = 9,    // CAS write latency
    parameter P_TBURST        = 4,    // burst duration (BL8/2)
    // Refresh timing
    parameter P_TREFI         = 12480, // 7800 ns / 0.625 ns
    parameter P_TRFC          = 560    // 350  ns / 0.625 ns
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // ------------------------------------------------------------------
    // AXI4 Host Interface
    // ------------------------------------------------------------------
    // Write address channel
    input  wire [AXI_ID_W-1:0]        s_axi_awid,
    input  wire [AXI_ADDR_W-1:0]      s_axi_awaddr,
    input  wire [7:0]                  s_axi_awlen,
    input  wire [2:0]                  s_axi_awsize,
    input  wire [1:0]                  s_axi_awburst,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    // Write data channel
    input  wire [AXI_DATA_W-1:0]      s_axi_wdata,
    input  wire [(AXI_DATA_W/8)-1:0]  s_axi_wstrb,
    input  wire                        s_axi_wlast,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    // Write response channel
    output wire [AXI_ID_W-1:0]        s_axi_bid,
    output wire [1:0]                  s_axi_bresp,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    // Read address channel
    input  wire [AXI_ID_W-1:0]        s_axi_arid,
    input  wire [AXI_ADDR_W-1:0]      s_axi_araddr,
    input  wire [7:0]                  s_axi_arlen,
    input  wire [2:0]                  s_axi_arsize,
    input  wire [1:0]                  s_axi_arburst,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    // Read data channel
    output wire [AXI_ID_W-1:0]        s_axi_rid,
    output wire [AXI_DATA_W-1:0]      s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,
    output wire                        s_axi_rlast,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,

    // ------------------------------------------------------------------
    // ECC Status
    // ------------------------------------------------------------------
    output wire                        ecc_single_err,
    output wire                        ecc_double_err,
    output reg  [AXI_ADDR_W-1:0]      ecc_err_addr,

    // ------------------------------------------------------------------
    // DDR4 DRAM Interface (to pads / PHY)
    // ------------------------------------------------------------------
    output wire [RANKS-1:0]            ddr4_ck_p,
    output wire [RANKS-1:0]            ddr4_ck_n,
    output wire [RANKS-1:0]            ddr4_cke,
    output wire [RANKS-1:0]            ddr4_cs_n,
    output wire                        ddr4_act_n,
    output wire                        ddr4_ras_n,
    output wire                        ddr4_cas_n,
    output wire                        ddr4_we_n,
    output wire [1:0]                  ddr4_ba,
    output wire [1:0]                  ddr4_bg,
    output wire [ROW_ADDR_W-1:0]       ddr4_addr,
    output wire [RANKS-1:0]            ddr4_odt,
    output wire                        ddr4_reset_n,
    inout  wire [63:0]                 ddr4_dq,
    inout  wire [7:0]                  ddr4_dqs_p,
    inout  wire [7:0]                  ddr4_dqs_n,
    inout  wire [7:0]                  ddr4_dm_dbi_n
);

    // ================================================================
    // Command encodings (shared across modules)
    // ================================================================
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // Total banks = BANK_GROUPS × BANKS_PER_GROUP; matches cmd_scheduler
    localparam TOTAL_BANKS = 16;

    // ================================================================
    // Internal wires: axi4_slave ↔ cmd_arbiter
    // ================================================================
    wire                    wr_valid_i;
    wire                    wr_ready_i;
    wire [AXI_ADDR_W-1:0]  wr_addr_i;
    wire [AXI_ID_W-1:0]    wr_id_i;

    wire                    rd_valid_i;
    wire                    rd_ready_i;
    wire [AXI_ADDR_W-1:0]  rd_addr_i;
    wire [AXI_ID_W-1:0]    rd_id_i;

    // Write data from AXI slave
    wire [AXI_DATA_W-1:0]      wr_data_i;
    wire [(AXI_DATA_W/8)-1:0]  wr_strb_i;
    wire                        wr_data_valid_i;
    wire                        rd_data_ready_i;

    // ================================================================
    // Internal wires: cmd_arbiter ↔ cmd_scheduler
    // ================================================================
    wire                    arb_valid_i;
    wire                    arb_ready_i;
    wire                    arb_is_write_i;
    wire [AXI_ADDR_W-1:0]  arb_addr_i;
    wire [AXI_ID_W-1:0]    arb_id_i;   // id not consumed by scheduler; tracked here

    // ================================================================
    // Internal wires: refresh_ctrl outputs
    // ================================================================
    wire ref_req_i;
    wire ref_issue_i;
    wire ref_stall_i;
    wire ref_active_i;
    wire [1:0] ref_bank_group_i;
    wire [1:0] ref_bank_i;

    // ================================================================
    // Internal wires: cmd_scheduler ↔ timing_ctrl
    // ================================================================
    wire [2:0] tc_cmd_i;
    wire [1:0] tc_bg_i;
    wire [1:0] tc_bank_i;
    wire       tc_ok_i;

    // ================================================================
    // Internal wires: cmd_scheduler DRAM command bus
    // ================================================================
    wire [2:0]           dram_cmd_i;
    wire [1:0]           dram_bg_i;
    wire [1:0]           dram_bank_i;
    wire [ROW_ADDR_W-1:0] dram_row_i;
    wire [COL_ADDR_W-1:0] dram_col_i;
    wire                 dram_valid_i;

    // ================================================================
    // Bank FSM: per-bank ready and row_active signals (16 banks)
    // ================================================================
    wire [TOTAL_BANKS-1:0] bank_fsm_ready;
    wire [TOTAL_BANKS-1:0] bank_row_active;

    // all_banks_idle: every bank is in the IDLE (precharged) state
    // IDLE <=> fsm_ready=1 AND row_active=0
    wire all_banks_idle;
    assign all_banks_idle = &(bank_fsm_ready & ~bank_row_active);

    // ================================================================
    // ECC encoder wires (write path)
    // ================================================================
    wire [7:0]  enc_check_i;
    wire [71:0] enc_word_i;  // {enc_check_i, wr_data_i}

    // ================================================================
    // PHY interface wires (read path)
    // ================================================================
    wire [63:0] phy_rd_dq_i;
    wire [7:0]  phy_rd_dm_i;
    wire        phy_rd_valid_i;

    // ================================================================
    // ECC decoder wires
    // ================================================================
    wire [63:0] dec_data_i;
    wire        dec_single_i;
    wire        dec_double_i;
    wire [7:0]  dec_syndrome_i;

    // ECC status outputs: pulse when read data returns with an error
    assign ecc_single_err = dec_single_i & phy_rd_valid_i;
    assign ecc_double_err = dec_double_i & phy_rd_valid_i;

    // Track the most recent read address for ECC error reporting.
    // The AXI slave holds rd_addr_i throughout the read transaction.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ecc_err_addr <= {AXI_ADDR_W{1'b0}};
        else if (phy_rd_valid_i && (dec_single_i || dec_double_i))
            ecc_err_addr <= rd_addr_i;
    end

    // ================================================================
    // PHY ctrl_addr mux: row address for ACT; column for RD/WR
    // ================================================================
    wire [ROW_ADDR_W-1:0] phy_ctrl_addr;
    assign phy_ctrl_addr =
        (dram_cmd_i == CMD_ACT) ? dram_row_i :
        {{(ROW_ADDR_W-COL_ADDR_W){1'b0}}, dram_col_i};

    // ================================================================
    // axi4_slave instantiation
    // ================================================================
    axi4_slave #(
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W),
        .AXI_ID_W   (AXI_ID_W)
    ) u_axi4_slave (
        .clk                (clk),
        .rst_n              (rst_n),
        // AXI4 Write Address channel
        .s_axi_awid         (s_axi_awid),
        .s_axi_awaddr       (s_axi_awaddr),
        .s_axi_awlen        (s_axi_awlen),
        .s_axi_awsize       (s_axi_awsize),
        .s_axi_awburst      (s_axi_awburst),
        .s_axi_awvalid      (s_axi_awvalid),
        .s_axi_awready      (s_axi_awready),
        // AXI4 Write Data channel
        .s_axi_wdata        (s_axi_wdata),
        .s_axi_wstrb        (s_axi_wstrb),
        .s_axi_wlast        (s_axi_wlast),
        .s_axi_wvalid       (s_axi_wvalid),
        .s_axi_wready       (s_axi_wready),
        // AXI4 Write Response channel
        .s_axi_bid          (s_axi_bid),
        .s_axi_bresp        (s_axi_bresp),
        .s_axi_bvalid       (s_axi_bvalid),
        .s_axi_bready       (s_axi_bready),
        // AXI4 Read Address channel
        .s_axi_arid         (s_axi_arid),
        .s_axi_araddr       (s_axi_araddr),
        .s_axi_arlen        (s_axi_arlen),
        .s_axi_arsize       (s_axi_arsize),
        .s_axi_arburst      (s_axi_arburst),
        .s_axi_arvalid      (s_axi_arvalid),
        .s_axi_arready      (s_axi_arready),
        // AXI4 Read Data channel
        .s_axi_rid          (s_axi_rid),
        .s_axi_rdata        (s_axi_rdata),
        .s_axi_rresp        (s_axi_rresp),
        .s_axi_rlast        (s_axi_rlast),
        .s_axi_rvalid       (s_axi_rvalid),
        .s_axi_rready       (s_axi_rready),
        // Write path to arbiter
        .wr_valid           (wr_valid_i),
        .wr_ready           (wr_ready_i),
        .wr_addr            (wr_addr_i),
        .wr_id              (wr_id_i),
        // Read path to arbiter
        .rd_valid           (rd_valid_i),
        .rd_ready           (rd_ready_i),
        .rd_addr            (rd_addr_i),
        .rd_id              (rd_id_i),
        // Write data path
        .wr_data            (wr_data_i),
        .wr_strb            (wr_strb_i),
        .wr_data_valid      (wr_data_valid_i),
        // Read data path (from ECC decoder via PHY)
        .rd_data            (dec_data_i),
        .rd_data_valid      (phy_rd_valid_i),
        .rd_ecc_single_err  (dec_single_i),
        .rd_ecc_double_err  (dec_double_i),
        .rd_data_ready      (rd_data_ready_i)
    );

    // ================================================================
    // cmd_arbiter instantiation
    // ================================================================
    cmd_arbiter #(
        .AXI_ADDR_W  (AXI_ADDR_W),
        .AXI_ID_W    (AXI_ID_W),
        .RD_PRIORITY (1)
    ) u_cmd_arbiter (
        .clk            (clk),
        .rst_n          (rst_n),
        // Refresh preemption
        .ref_req        (ref_req_i),
        // Read path
        .rd_valid       (rd_valid_i),
        .rd_ready       (rd_ready_i),
        .rd_addr        (rd_addr_i),
        .rd_id          (rd_id_i),
        // Write path
        .wr_valid       (wr_valid_i),
        .wr_ready       (wr_ready_i),
        .wr_addr        (wr_addr_i),
        .wr_id          (wr_id_i),
        // Output to scheduler
        .arb_valid      (arb_valid_i),
        .arb_ready      (arb_ready_i),
        .arb_is_write   (arb_is_write_i),
        .arb_addr       (arb_addr_i),
        .arb_id         (arb_id_i)
    );

    // ================================================================
    // cmd_scheduler instantiation
    // ================================================================
    cmd_scheduler #(
        .AXI_ADDR_W      (AXI_ADDR_W),
        .AXI_ID_W        (AXI_ID_W),
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
        .ROW_ADDR_W      (ROW_ADDR_W),
        .COL_ADDR_W      (COL_ADDR_W)
    ) u_cmd_scheduler (
        .clk            (clk),
        .rst_n          (rst_n),
        // From arbiter
        .arb_valid      (arb_valid_i),
        .arb_ready      (arb_ready_i),
        .arb_is_write   (arb_is_write_i),
        .arb_addr       (arb_addr_i),
        // Refresh interface
        .ref_req        (ref_req_i),
        .ref_issue      (ref_issue_i),
        // Timing controller
        .tc_cmd         (tc_cmd_i),
        .tc_bank_group  (tc_bg_i),
        .tc_bank        (tc_bank_i),
        .tc_ok          (tc_ok_i),
        // DRAM command bus
        .dram_cmd       (dram_cmd_i),
        .dram_bank_group(dram_bg_i),
        .dram_bank      (dram_bank_i),
        .dram_row_addr  (dram_row_i),
        .dram_col_addr  (dram_col_i),
        .dram_valid     (dram_valid_i)
    );

    // ================================================================
    // refresh_ctrl instantiation
    // ================================================================
    refresh_ctrl #(
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
        .P_TREFI         (P_TREFI),
        .P_TRFC          (P_TRFC)
    ) u_refresh_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .all_banks_idle (all_banks_idle),
        .rfsh_mode      (1'b0),         // REFab by default
        .temp_throttle  (1'b0),         // normal temperature
        .ref_req        (ref_req_i),
        .ref_issue      (ref_issue_i),
        .ref_stall      (ref_stall_i),
        .ref_active     (ref_active_i),
        .ref_bank_group (ref_bank_group_i),
        .ref_bank       (ref_bank_i)
    );

    // ================================================================
    // timing_ctrl instantiation
    // ================================================================
    timing_ctrl #(
        .BANK_GROUPS     (BANK_GROUPS),
        .BANKS_PER_GROUP (BANKS_PER_GROUP),
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
        .P_TWR           (P_TWR)
    ) u_timing_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .tc_cmd         (tc_cmd_i),
        .tc_bank_group  (tc_bg_i),
        .tc_bank        (tc_bank_i),
        .tc_ok          (tc_ok_i)
    );

    // ================================================================
    // bank_fsm generate block – 16 instances
    // Each instance responds only to commands whose {bg, bank} matches
    // its flat index: bank_idx = {bank_group[1:0], bank[1:0]}
    // ================================================================
    genvar g;
    generate
        for (g = 0; g < TOTAL_BANKS; g = g + 1) begin : gen_bank_fsm
            wire [1:0] g_bg   = g[3:2];
            wire [1:0] g_bank = g[1:0];
            wire       g_cmd_valid = dram_valid_i &&
                                     (dram_bg_i   == g_bg) &&
                                     (dram_bank_i == g_bank);
            wire [ROW_ADDR_W-1:0] g_open_row;
            wire                  g_tras_ok;
            wire [1:0]            g_state_out;

            bank_fsm #(
                .ROW_ADDR_W (ROW_ADDR_W),
                .P_TRCD     (P_TRCD),
                .P_TRAS     (P_TRAS),
                .P_TRP      (P_TRP)
            ) u_bank_fsm (
                .clk         (clk),
                .rst_n       (rst_n),
                .cmd_in      (dram_cmd_i),
                .row_addr_in (dram_row_i),
                .cmd_valid   (g_cmd_valid),
                .fsm_ready   (bank_fsm_ready  [g]),
                .open_row    (g_open_row),
                .row_active  (bank_row_active [g]),
                .tras_ok     (g_tras_ok),
                .state_out   (g_state_out)
            );
        end
    endgenerate

    // ================================================================
    // ecc_encoder instantiation (write path)
    // ================================================================
    ecc_encoder u_ecc_encoder (
        .enc_data_in  (wr_data_i),
        .enc_check_out(enc_check_i),
        .enc_word_out (enc_word_i)
    );

    // ================================================================
    // ecc_decoder instantiation (read path)
    // ================================================================
    ecc_decoder u_ecc_decoder (
        .dec_word_in   ({phy_rd_dm_i, phy_rd_dq_i}),
        .dec_data_out  (dec_data_i),
        .dec_single_err(dec_single_i),
        .dec_double_err(dec_double_i),
        .dec_syndrome  (dec_syndrome_i)
    );

    // ================================================================
    // phy_if instantiation
    // ================================================================
    phy_if #(
        .RANKS      (RANKS),
        .DQ_WIDTH   (64),
        .DQS_WIDTH  (8),
        .DM_WIDTH   (8),
        .ROW_ADDR_W (ROW_ADDR_W),
        .COL_ADDR_W (COL_ADDR_W),
        .P_TCL      (P_TCL),
        .P_TCWL     (P_TCWL),
        .P_TBURST   (P_TBURST)
    ) u_phy_if (
        .clk            (clk),
        .rst_n          (rst_n),
        // Command from scheduler
        .ctrl_cmd       (dram_cmd_i),
        .ctrl_bg        (dram_bg_i),
        .ctrl_ba        (dram_bank_i),
        .ctrl_addr      (phy_ctrl_addr),
        .ctrl_cmd_valid (dram_valid_i),
        // Write data path (ECC-encoded)
        .wr_dq          (wr_data_i),
        .wr_dm          (enc_check_i),
        .wr_data_valid  (wr_data_valid_i),
        // Read data path
        .rd_dq          (phy_rd_dq_i),
        .rd_dm          (phy_rd_dm_i),
        .rd_data_valid  (phy_rd_valid_i),
        // Calibration / init
        .wl_mode        (1'b0),
        .wl_done        (),
        .init_done      (rst_n),
        // Debug
        .dq_oe          (),
        .dqs_oe         (),
        // DDR4 pad interface
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

endmodule

`default_nettype wire
