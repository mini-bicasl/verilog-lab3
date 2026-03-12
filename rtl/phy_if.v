// phy_if.v – DDR4 PHY Interface
//
// RTL wrapper modelling the DDR4 PHY/pad interface.  Vendor-specific
// DLL/PLL calibration is out of scope.  This module provides:
//
//   - DDR4 command bus output (ACT_n, RAS_n/A16, CAS_n/A15, WE_n/A14,
//     BA[1:0], BG[1:0], ADDR[16:0])
//   - DQ/DQS bidir direction control:
//       write path → DQ driven;  read path → DQ Hi-Z (DRAM drives)
//   - DQS write preamble: 1 controller-clock DQS_p=0 before first toggle
//   - DQS write postamble: 1 controller-clock DQS_p=0 after last toggle
//   - Write data sequencing: waits P_TCWL clocks from WR command before
//     starting the DQS preamble
//   - Read data capture: samples DQ P_TCL clocks after RD command
//   - Write-leveling calibration mode: drives DQS and counts wl_done
//
// Clock domain notes:
//   One controller clock = half the DRAM data-rate clock (half-rate domain).
//   DQS toggles every controller clock during the burst, modelling the
//   double-data-rate strobe at the DRAM pins.
//
// Write FSM states:
//   WR_IDLE  – idle, DQ/DQS Hi-Z
//   WR_CWL   – counting P_TCWL cycles from WR command
//   WR_PRE   – preamble: registers DQS_p=0, asserts OE (outputs appear next clock)
//   WR_DATA  – burst: DQS_p toggles each clock, DQ driven for P_TBURST clocks
//   WR_POST  – postamble: DQS_p=0 (from final toggle), releases OE next clock
//
// Reset: active-low asynchronous (negedge rst_n in sensitivity list).
//
// Compile & run:
//   iverilog -g2012 -o build/phy_if.out tb/phy_if_tb.v rtl/phy_if.v
//   vvp build/phy_if.out

`default_nettype none

module phy_if #(
    parameter RANKS      = 1,
    parameter DQ_WIDTH   = 64,
    parameter DQS_WIDTH  = 8,
    parameter DM_WIDTH   = 8,
    parameter ROW_ADDR_W = 17,
    parameter COL_ADDR_W = 10,
    parameter P_TCL      = 11,  // CAS latency (controller clocks, >= 1)
    parameter P_TCWL     = 9,   // CAS write latency (controller clocks, >= 2)
    parameter P_TBURST   = 4    // Write burst duration (controller clocks; BL8/2)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ------------------------------------------------------------------
    // Controller-facing: command from cmd_scheduler
    // ------------------------------------------------------------------
    input  wire [2:0]              ctrl_cmd,
    input  wire [1:0]              ctrl_bg,
    input  wire [1:0]              ctrl_ba,
    input  wire [ROW_ADDR_W-1:0]   ctrl_addr,
    input  wire                    ctrl_cmd_valid,

    // Write data path (from write buffer / ECC encoder, 64-bit + 8-bit DM)
    input  wire [DQ_WIDTH-1:0]     wr_dq,         // 64-bit write data
    input  wire [DM_WIDTH-1:0]     wr_dm,         // 8-bit data mask / ECC check bits
    input  wire                    wr_data_valid,  // data available this cycle

    // Read data path (to ECC decoder / read buffer)
    output reg  [DQ_WIDTH-1:0]     rd_dq,          // captured 64-bit read data
    output reg  [DM_WIDTH-1:0]     rd_dm,          // captured DM/DBI bits
    output reg                     rd_data_valid,  // 1-cycle pulse: rd_dq/rd_dm valid

    // Write-leveling calibration
    input  wire                    wl_mode,        // request write-leveling mode
    output reg                     wl_done,        // leveling complete

    // DRAM initialization gate
    input  wire                    init_done,      // enables CKE / deasserts CS_n

    // Debug / status (useful for testbench probing)
    output wire                    dq_oe,          // 1 = DQ bus driven by controller
    output wire                    dqs_oe,         // 1 = DQS driven by controller

    // ------------------------------------------------------------------
    // DDR4 DRAM pins
    // ------------------------------------------------------------------
    output wire [RANKS-1:0]        ddr4_ck_p,
    output wire [RANKS-1:0]        ddr4_ck_n,
    output wire [RANKS-1:0]        ddr4_cke,
    output wire [RANKS-1:0]        ddr4_cs_n,
    output reg                     ddr4_act_n,
    output reg                     ddr4_ras_n,     // A16 when ACT_n=1
    output reg                     ddr4_cas_n,     // A15 when ACT_n=1
    output reg                     ddr4_we_n,      // A14 when ACT_n=1
    output reg  [1:0]              ddr4_ba,
    output reg  [1:0]              ddr4_bg,
    output reg  [ROW_ADDR_W-1:0]   ddr4_addr,
    output wire [RANKS-1:0]        ddr4_odt,
    output wire                    ddr4_reset_n,

    // Bidirectional data bus
    inout  wire [DQ_WIDTH-1:0]     ddr4_dq,
    inout  wire [DQS_WIDTH-1:0]    ddr4_dqs_p,
    inout  wire [DQS_WIDTH-1:0]    ddr4_dqs_n,
    inout  wire [DM_WIDTH-1:0]     ddr4_dm_dbi_n
);

    // ---------------------------------------------------------------
    // Command encodings (match cmd_scheduler / bank_fsm convention)
    // ---------------------------------------------------------------
    localparam CMD_NOP = 3'd0;
    localparam CMD_ACT = 3'd1;
    localparam CMD_RD  = 3'd2;
    localparam CMD_WR  = 3'd3;
    localparam CMD_PRE = 3'd4;
    localparam CMD_REF = 3'd5;

    // ---------------------------------------------------------------
    // Write burst FSM states
    // ---------------------------------------------------------------
    localparam WR_IDLE = 3'd0;
    localparam WR_CWL  = 3'd1;  // count P_TCWL clocks from WR command
    localparam WR_PRE  = 3'd2;  // register preamble values (visible next clock)
    localparam WR_DATA = 3'd3;  // burst: DQS toggles, DQ driven
    localparam WR_POST = 3'd4;  // postamble: DQS_p=0 (from last toggle); release OE

    // ---------------------------------------------------------------
    // Write-leveling calibration period (simulated)
    // ---------------------------------------------------------------
    localparam WL_CALIB_CYCLES = 8;

    // ---------------------------------------------------------------
    // Static DDR4 pin assignments
    // ---------------------------------------------------------------
    // Differential clock mirrors system clock
    assign ddr4_ck_p    = {RANKS{clk}};
    assign ddr4_ck_n    = {RANKS{~clk}};
    // CKE: enabled when DRAM initialisation is done
    assign ddr4_cke     = {RANKS{init_done}};
    // CS_n: active-low, deasserted after reset AND init
    assign ddr4_cs_n    = {RANKS{~(rst_n & init_done)}};
    // ODT not driven in this RTL model
    assign ddr4_odt     = {RANKS{1'b0}};
    // DRAM reset mirrors system reset
    assign ddr4_reset_n = rst_n;

    // ---------------------------------------------------------------
    // Internal registers
    // ---------------------------------------------------------------
    reg [2:0]           wr_state;
    reg [7:0]           wr_cnt;
    reg [DQ_WIDTH-1:0]  wr_buf_dq;
    reg [DM_WIDTH-1:0]  wr_buf_dm;

    reg                 dq_oe_r;
    reg                 dqs_oe_r;
    reg [DQ_WIDTH-1:0]  dq_out_r;
    reg [DM_WIDTH-1:0]  dm_out_r;
    reg [DQS_WIDTH-1:0] dqs_p_out_r;  // DQS_p driven value

    reg [7:0]           rd_cnt;
    reg                 rd_armed;

    reg [7:0]           wl_cnt;
    reg                 wl_dqs_r;     // DQS driven during WL (toggling)

    // ---------------------------------------------------------------
    // Expose OE status signals
    // ---------------------------------------------------------------
    assign dq_oe  = dq_oe_r;
    assign dqs_oe = dqs_oe_r | (wl_mode & ~wl_done);

    // ---------------------------------------------------------------
    // Bidir pad assignments
    //   DQS_n is always complementary to DQS_p (differential pair)
    // ---------------------------------------------------------------
    assign ddr4_dq      = dq_oe_r               ? dq_out_r    : {DQ_WIDTH{1'bz}};
    assign ddr4_dm_dbi_n= dq_oe_r               ? dm_out_r    : {DM_WIDTH{1'bz}};

    wire dqs_drive = dqs_oe_r | (wl_mode & ~wl_done);
    wire [DQS_WIDTH-1:0] dqs_p_val = (wl_mode & ~wl_done) ?
                                       {DQS_WIDTH{wl_dqs_r}} : dqs_p_out_r;

    assign ddr4_dqs_p   = dqs_drive ? dqs_p_val          : {DQS_WIDTH{1'bz}};
    assign ddr4_dqs_n   = dqs_drive ? (~dqs_p_val)        : {DQS_WIDTH{1'bz}};

    // ---------------------------------------------------------------
    // Sequential: DDR4 command bus output
    //   Registered to meet setup/hold at DRAM clock input.
    //   NOP is driven when ctrl_cmd_valid is de-asserted.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr4_act_n <= 1'b1;
            ddr4_ras_n <= 1'b1;
            ddr4_cas_n <= 1'b1;
            ddr4_we_n  <= 1'b1;
            ddr4_ba    <= 2'b00;
            ddr4_bg    <= 2'b00;
            ddr4_addr  <= {ROW_ADDR_W{1'b0}};
        end else begin
            ddr4_ba   <= ctrl_ba;
            ddr4_bg   <= ctrl_bg;
            ddr4_addr <= ctrl_addr;

            if (ctrl_cmd_valid) begin
                case (ctrl_cmd)
                    // ACTIVATE: ACT_n=0 (row address on ADDR)
                    CMD_ACT: begin
                        ddr4_act_n <= 1'b0;
                        ddr4_ras_n <= 1'b1;
                        ddr4_cas_n <= 1'b1;
                        ddr4_we_n  <= 1'b1;
                    end
                    // READ: ACT_n=1, CAS_n=0, WE_n=1
                    CMD_RD: begin
                        ddr4_act_n <= 1'b1;
                        ddr4_ras_n <= 1'b1;
                        ddr4_cas_n <= 1'b0;
                        ddr4_we_n  <= 1'b1;
                    end
                    // WRITE: ACT_n=1, CAS_n=0, WE_n=0
                    CMD_WR: begin
                        ddr4_act_n <= 1'b1;
                        ddr4_ras_n <= 1'b1;
                        ddr4_cas_n <= 1'b0;
                        ddr4_we_n  <= 1'b0;
                    end
                    // PRECHARGE: ACT_n=1, RAS_n=0, CAS_n=1, WE_n=0
                    CMD_PRE: begin
                        ddr4_act_n <= 1'b1;
                        ddr4_ras_n <= 1'b0;
                        ddr4_cas_n <= 1'b1;
                        ddr4_we_n  <= 1'b0;
                    end
                    // REFRESH: ACT_n=1, RAS_n=0, CAS_n=0, WE_n=1
                    CMD_REF: begin
                        ddr4_act_n <= 1'b1;
                        ddr4_ras_n <= 1'b0;
                        ddr4_cas_n <= 1'b0;
                        ddr4_we_n  <= 1'b1;
                    end
                    // NOP / default
                    default: begin
                        ddr4_act_n <= 1'b1;
                        ddr4_ras_n <= 1'b1;
                        ddr4_cas_n <= 1'b1;
                        ddr4_we_n  <= 1'b1;
                    end
                endcase
            end else begin
                // No valid command: drive NOP
                ddr4_act_n <= 1'b1;
                ddr4_ras_n <= 1'b1;
                ddr4_cas_n <= 1'b1;
                ddr4_we_n  <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Write data latch
    //   Captures wr_dq/wr_dm whenever wr_data_valid is asserted.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_buf_dq <= {DQ_WIDTH{1'b0}};
            wr_buf_dm <= {DM_WIDTH{1'b0}};
        end else if (wr_data_valid) begin
            wr_buf_dq <= wr_dq;
            wr_buf_dm <= wr_dm;
        end
    end

    // ---------------------------------------------------------------
    // Write burst FSM
    //
    //  Timing (registered outputs – values appear one clock after assignment):
    //
    //    Clock T    : WR command received, enter WR_CWL
    //    Clock T+P_TCWL-1 : WR_CWL exits (cnt reaches 0), enter WR_PRE
    //    Clock T+P_TCWL   : WR_PRE registers dqs_p=0, oe=1; state→WR_DATA
    //    Clock T+P_TCWL+1 : WR_DATA[0] – DQS_p=0 visible (preamble), toggles→1
    //    Clock T+P_TCWL+2 : WR_DATA[1] – DQS_p=1 visible, toggles→0
    //    ...
    //    Clock T+P_TCWL+P_TBURST : WR_DATA last – DQS_p=1, toggles→0; state→WR_POST
    //    Clock T+P_TCWL+P_TBURST+1 : WR_POST – DQS_p=0 visible (postamble); oe clears
    //    Clock T+P_TCWL+P_TBURST+2 : WR_IDLE – DQ/DQS Hi-Z
    //
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state    <= WR_IDLE;
            wr_cnt      <= 8'd0;
            dq_oe_r     <= 1'b0;
            dqs_oe_r    <= 1'b0;
            dq_out_r    <= {DQ_WIDTH{1'b0}};
            dm_out_r    <= {DM_WIDTH{1'b0}};
            dqs_p_out_r <= {DQS_WIDTH{1'b0}};
        end else begin
            case (wr_state)

                // ---- IDLE: wait for WR command ---------------------
                WR_IDLE: begin
                    dq_oe_r  <= 1'b0;
                    dqs_oe_r <= 1'b0;
                    if (ctrl_cmd_valid && ctrl_cmd == CMD_WR) begin
                        // Count P_TCWL - 2 cycles in WR_CWL so that
                        // WR_PRE starts exactly P_TCWL - 1 clocks after
                        // the WR command, and first data is visible at
                        // clock T + P_TCWL + 1 (= CWL + 1 beats total).
                        wr_cnt   <= (P_TCWL >= 2) ? (P_TCWL - 2) : 8'd0;
                        wr_state <= WR_CWL;
                    end
                end

                // ---- CWL countdown ---------------------------------
                WR_CWL: begin
                    if (wr_cnt == 8'd0) begin
                        wr_state <= WR_PRE;
                    end else begin
                        wr_cnt <= wr_cnt - 8'd1;
                    end
                end

                // ---- Preamble: register OE and DQS_p=0 ------------
                //   Outputs become visible on the NEXT clock (WR_DATA[0]).
                WR_PRE: begin
                    dq_oe_r     <= 1'b1;
                    dqs_oe_r    <= 1'b1;
                    dqs_p_out_r <= {DQS_WIDTH{1'b0}};  // preamble low
                    dq_out_r    <= wr_buf_dq;
                    dm_out_r    <= wr_buf_dm;
                    wr_cnt      <= P_TBURST - 1;
                    wr_state    <= WR_DATA;
                end

                // ---- Burst data: DQS toggles each clock ------------
                //   dqs_p_out_r starts at 0 (set by WR_PRE) and toggles:
                //     WR_DATA[0]: visible=0 (preamble), toggles → 1
                //     WR_DATA[1]: visible=1, toggles → 0
                //     ... (P_TBURST total clocks)
                //     WR_DATA[P_TBURST-1]: visible=1, toggles → 0  (postamble seed)
                WR_DATA: begin
                    dqs_p_out_r <= ~dqs_p_out_r;  // toggle
                    dq_out_r    <= wr_buf_dq;
                    dm_out_r    <= wr_buf_dm;
                    if (wr_cnt == 8'd0) begin
                        wr_state <= WR_POST;
                    end else begin
                        wr_cnt <= wr_cnt - 8'd1;
                    end
                end

                // ---- Postamble: DQS_p=0 still visible (from last toggle)
                //   dqs_oe stays 1 during this cycle; cleared next clock
                //   when FSM returns to WR_IDLE.
                WR_POST: begin
                    dq_oe_r  <= 1'b0;   // DQ → Hi-Z next clock
                    dqs_oe_r <= 1'b0;   // DQS → Hi-Z next clock
                    wr_state <= WR_IDLE;
                end

                default: wr_state <= WR_IDLE;

            endcase
        end
    end

    // ---------------------------------------------------------------
    // Read data capture
    //   P_TCL clocks after a RD command, sample DQ/DM from the DRAM.
    //   In a real PHY the capture uses the incoming DQS strobe; here
    //   we model the fixed latency and capture from the inout wire.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_cnt        <= 8'd0;
            rd_armed      <= 1'b0;
            rd_dq         <= {DQ_WIDTH{1'b0}};
            rd_dm         <= {DM_WIDTH{1'b0}};
            rd_data_valid <= 1'b0;
        end else begin
            rd_data_valid <= 1'b0;  // default: de-assert

            if (ctrl_cmd_valid && ctrl_cmd == CMD_RD) begin
                rd_cnt   <= (P_TCL >= 1) ? (P_TCL - 1) : 8'd0;
                rd_armed <= 1'b1;
            end else if (rd_armed) begin
                if (rd_cnt == 8'd0) begin
                    rd_dq         <= ddr4_dq;
                    rd_dm         <= ddr4_dm_dbi_n;
                    rd_data_valid <= 1'b1;
                    rd_armed      <= 1'b0;
                end else begin
                    rd_cnt <= rd_cnt - 8'd1;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Write-leveling calibration
    //   When wl_mode=1, DQS is driven (handled in bidir assigns above)
    //   and a simulated calibration counter runs.  wl_done asserts
    //   after WL_CALIB_CYCLES clocks and remains high until wl_mode
    //   is de-asserted.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wl_cnt   <= 8'd0;
            wl_done  <= 1'b0;
            wl_dqs_r <= 1'b0;
        end else if (wl_mode && !wl_done) begin
            wl_dqs_r <= ~wl_dqs_r;             // toggle DQS for leveling
            if (wl_cnt == WL_CALIB_CYCLES - 1) begin
                wl_done <= 1'b1;
            end else begin
                wl_cnt <= wl_cnt + 8'd1;
            end
        end else if (!wl_mode) begin
            wl_done  <= 1'b0;
            wl_cnt   <= 8'd0;
            wl_dqs_r <= 1'b0;
        end
    end

endmodule

`default_nettype wire
