// axi4_slave_tb.v – Testbench for axi4_slave
//
// Uses compact parameters to keep stimulus readable:
//   AXI_ADDR_W = 16
//   AXI_DATA_W = 32
//   AXI_ID_W   = 4
//
// Tests:
//   T1:  Reset – all outputs de-asserted; awready/arready high (IDLE)
//   T2:  Write round-trip – AW → W → wr_valid/arbiter accept → B OKAY
//   T3:  Read round-trip  – AR → rd_valid/arbiter accept → rd_data → R OKAY
//   T4:  Write ID forwarding – awid=0xA → bid=0xA
//   T5:  Read  ID forwarding – arid=0xB → rid=0xB
//   T6:  Back-pressure on B channel – bready held low; bvalid stays high
//   T7:  Back-pressure on R channel – rready held low; rvalid stays high
//   T8:  SLVERR on double-bit ECC error – rd_ecc_double_err → rresp=SLVERR
//
// Compile & run:
//   iverilog -g2012 -o build/axi4_slave.out tb/axi4_slave_tb.v rtl/axi4_slave.v
//   vvp build/axi4_slave.out

`timescale 1ns/1ps

module axi4_slave_tb;

    // ----------------------------------------------------------------
    // Parameters (compact for readability)
    // ----------------------------------------------------------------
    localparam AXI_ADDR_W = 16;
    localparam AXI_DATA_W = 32;
    localparam AXI_ID_W   = 4;
    localparam STRB_W     = AXI_DATA_W / 8;   // 4

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg  clk;
    reg  rst_n;

    // Write Address channel
    reg  [AXI_ID_W-1:0]   s_axi_awid;
    reg  [AXI_ADDR_W-1:0] s_axi_awaddr;
    reg  [7:0]             s_axi_awlen;
    reg  [2:0]             s_axi_awsize;
    reg  [1:0]             s_axi_awburst;
    reg                    s_axi_awvalid;
    wire                   s_axi_awready;

    // Write Data channel
    reg  [AXI_DATA_W-1:0] s_axi_wdata;
    reg  [STRB_W-1:0]     s_axi_wstrb;
    reg                    s_axi_wlast;
    reg                    s_axi_wvalid;
    wire                   s_axi_wready;

    // Write Response channel
    wire [AXI_ID_W-1:0]   s_axi_bid;
    wire [1:0]             s_axi_bresp;
    wire                   s_axi_bvalid;
    reg                    s_axi_bready;

    // Read Address channel
    reg  [AXI_ID_W-1:0]   s_axi_arid;
    reg  [AXI_ADDR_W-1:0] s_axi_araddr;
    reg  [7:0]             s_axi_arlen;
    reg  [2:0]             s_axi_arsize;
    reg  [1:0]             s_axi_arburst;
    reg                    s_axi_arvalid;
    wire                   s_axi_arready;

    // Read Data channel
    wire [AXI_ID_W-1:0]   s_axi_rid;
    wire [AXI_DATA_W-1:0] s_axi_rdata;
    wire [1:0]             s_axi_rresp;
    wire                   s_axi_rlast;
    wire                   s_axi_rvalid;
    reg                    s_axi_rready;

    // Arbiter interface (mock)
    wire                   wr_valid;
    reg                    wr_ready;
    wire [AXI_ADDR_W-1:0] wr_addr;
    wire [AXI_ID_W-1:0]   wr_id;

    wire                   rd_valid;
    reg                    rd_ready;
    wire [AXI_ADDR_W-1:0] rd_addr;
    wire [AXI_ID_W-1:0]   rd_id;

    // Write data path (observe only)
    wire [AXI_DATA_W-1:0] wr_data;
    wire [STRB_W-1:0]     wr_strb;
    wire                   wr_data_valid;

    // Read data path (mock)
    reg  [AXI_DATA_W-1:0] rd_data;
    reg                    rd_data_valid;
    reg                    rd_ecc_single_err;
    reg                    rd_ecc_double_err;
    wire                   rd_data_ready;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    axi4_slave #(
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_DATA_W (AXI_DATA_W),
        .AXI_ID_W   (AXI_ID_W)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axi_awid       (s_axi_awid),
        .s_axi_awaddr     (s_axi_awaddr),
        .s_axi_awlen      (s_axi_awlen),
        .s_axi_awsize     (s_axi_awsize),
        .s_axi_awburst    (s_axi_awburst),
        .s_axi_awvalid    (s_axi_awvalid),
        .s_axi_awready    (s_axi_awready),
        .s_axi_wdata      (s_axi_wdata),
        .s_axi_wstrb      (s_axi_wstrb),
        .s_axi_wlast      (s_axi_wlast),
        .s_axi_wvalid     (s_axi_wvalid),
        .s_axi_wready     (s_axi_wready),
        .s_axi_bid        (s_axi_bid),
        .s_axi_bresp      (s_axi_bresp),
        .s_axi_bvalid     (s_axi_bvalid),
        .s_axi_bready     (s_axi_bready),
        .s_axi_arid       (s_axi_arid),
        .s_axi_araddr     (s_axi_araddr),
        .s_axi_arlen      (s_axi_arlen),
        .s_axi_arsize     (s_axi_arsize),
        .s_axi_arburst    (s_axi_arburst),
        .s_axi_arvalid    (s_axi_arvalid),
        .s_axi_arready    (s_axi_arready),
        .s_axi_rid        (s_axi_rid),
        .s_axi_rdata      (s_axi_rdata),
        .s_axi_rresp      (s_axi_rresp),
        .s_axi_rlast      (s_axi_rlast),
        .s_axi_rvalid     (s_axi_rvalid),
        .s_axi_rready     (s_axi_rready),
        .wr_valid         (wr_valid),
        .wr_ready         (wr_ready),
        .wr_addr          (wr_addr),
        .wr_id            (wr_id),
        .rd_valid         (rd_valid),
        .rd_ready         (rd_ready),
        .rd_addr          (rd_addr),
        .rd_id            (rd_id),
        .wr_data          (wr_data),
        .wr_strb          (wr_strb),
        .wr_data_valid    (wr_data_valid),
        .rd_data          (rd_data),
        .rd_data_valid    (rd_data_valid),
        .rd_ecc_single_err(rd_ecc_single_err),
        .rd_ecc_double_err(rd_ecc_double_err),
        .rd_data_ready    (rd_data_ready)
    );

    // ----------------------------------------------------------------
    // Clock – 10 ns period (100 MHz)
    // ----------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // ----------------------------------------------------------------
    // VCD waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-axi/axi4_slave.vcd");
        $dumpvars(0, axi4_slave_tb);
    end

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
                $display("FAIL T%0d: %s", tid, msg);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Advance one clock cycle and sample outputs 1 ns after the edge
    task clk_cycle;
        begin
            @(posedge clk); #1;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: drive AW channel for one beat
    // ----------------------------------------------------------------
    task drive_aw;
        input [AXI_ID_W-1:0]   id;
        input [AXI_ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            s_axi_awid    = id;
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            @(posedge clk); #1;
            // awready is combinational from WS_IDLE state; handshake occurs
            s_axi_awvalid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: drive W channel for one beat
    // ----------------------------------------------------------------
    task drive_w;
        input [AXI_DATA_W-1:0] data;
        input [STRB_W-1:0]     strb;
        begin
            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wlast  = 1'b1;
            s_axi_wvalid = 1'b1;
            @(posedge clk); #1;
            // wready is combinational from WS_WAIT_W; handshake occurs
            s_axi_wvalid = 1'b0;
            s_axi_wlast  = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: drive AR channel for one beat
    // ----------------------------------------------------------------
    task drive_ar;
        input [AXI_ID_W-1:0]   id;
        input [AXI_ADDR_W-1:0] addr;
        begin
            @(negedge clk);
            s_axi_arid    = id;
            s_axi_araddr  = addr;
            s_axi_arvalid = 1'b1;
            @(posedge clk); #1;
            s_axi_arvalid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: mock arbiter accepts write/read after 1 cycle
    // ----------------------------------------------------------------
    task arb_accept_wr;
        begin
            @(negedge clk); wr_ready = 1'b1;
            @(posedge clk); #1;
            wr_ready = 1'b0;
        end
    endtask

    task arb_accept_rd;
        begin
            @(negedge clk); rd_ready = 1'b1;
            @(posedge clk); #1;
            rd_ready = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: mock read data return (no ECC error)
    // ----------------------------------------------------------------
    task return_rd_data;
        input [AXI_DATA_W-1:0] data;
        begin
            @(negedge clk);
            rd_data          = data;
            rd_ecc_double_err = 1'b0;
            rd_ecc_single_err = 1'b0;
            rd_data_valid    = 1'b1;
            @(posedge clk); #1;
            rd_data_valid = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Helper: mock read data return (double-bit ECC error)
    // ----------------------------------------------------------------
    task return_rd_data_dbe;
        input [AXI_DATA_W-1:0] data;
        begin
            @(negedge clk);
            rd_data           = data;
            rd_ecc_double_err = 1'b1;
            rd_ecc_single_err = 1'b0;
            rd_data_valid     = 1'b1;
            @(posedge clk); #1;
            rd_data_valid     = 1'b0;
            rd_ecc_double_err = 1'b0;
        end
    endtask

    // ================================================================
    // Main test sequencer
    // ================================================================
    initial begin
        pass_count = 0;
        fail_count = 0;

        // Default stimulus
        rst_n          = 1'b0;
        s_axi_awid     = {AXI_ID_W{1'b0}};
        s_axi_awaddr   = {AXI_ADDR_W{1'b0}};
        s_axi_awlen    = 8'd0;
        s_axi_awsize   = 3'd2;
        s_axi_awburst  = 2'b01;  // INCR
        s_axi_awvalid  = 1'b0;
        s_axi_wdata    = {AXI_DATA_W{1'b0}};
        s_axi_wstrb    = {STRB_W{1'b1}};
        s_axi_wlast    = 1'b0;
        s_axi_wvalid   = 1'b0;
        s_axi_bready   = 1'b0;
        s_axi_arid     = {AXI_ID_W{1'b0}};
        s_axi_araddr   = {AXI_ADDR_W{1'b0}};
        s_axi_arlen    = 8'd0;
        s_axi_arsize   = 3'd2;
        s_axi_arburst  = 2'b01;
        s_axi_arvalid  = 1'b0;
        s_axi_rready   = 1'b0;
        wr_ready       = 1'b0;
        rd_ready       = 1'b0;
        rd_data        = {AXI_DATA_W{1'b0}};
        rd_data_valid  = 1'b0;
        rd_ecc_single_err = 1'b0;
        rd_ecc_double_err = 1'b0;

        // ===========================================================
        // T1: Reset state
        // ===========================================================
        repeat(4) @(posedge clk);
        #1;
        chk(s_axi_bvalid  == 1'b0, 1, "reset: bvalid=0");
        chk(s_axi_rvalid  == 1'b0, 1, "reset: rvalid=0");
        chk(wr_valid       == 1'b0, 1, "reset: wr_valid=0");
        chk(rd_valid       == 1'b0, 1, "reset: rd_valid=0");

        // Release reset; give one idle cycle
        @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // Ready signals should be high after reset
        chk(s_axi_awready == 1'b1, 1, "post-reset: awready=1");
        chk(s_axi_arready == 1'b1, 1, "post-reset: arready=1");
        chk(s_axi_wready  == 1'b0, 1, "post-reset: wready=0 (no AW pending)");

        // ===========================================================
        // T2: Write round-trip (AW → W → arbiter accept → B OKAY)
        // ===========================================================

        // Present AW: awready=1 in WS_IDLE, handshake occurs at posedge
        drive_aw(4'h1, 16'h1000);

        // DUT now in WS_WAIT_W; wready should be high
        chk(s_axi_wready  == 1'b1, 2, "write: wready=1 after AW accepted");
        chk(s_axi_awready == 1'b0, 2, "write: awready=0 while waiting for W");

        // Present W data
        drive_w(32'hDEAD_BEEF, 4'hF);

        // DUT now in WS_ARB; wr_valid should be high
        chk(wr_valid == 1'b1, 2, "write: wr_valid=1 after W accepted");
        chk(wr_addr  == 16'h1000, 2, "write: wr_addr correct");

        // Mock arbiter accepts the write request
        arb_accept_wr;

        // DUT now in WS_RESP: bvalid should be asserted
        chk(s_axi_bvalid == 1'b1, 2, "write: bvalid=1 after arbiter accepts");
        chk(s_axi_bresp  == 2'b00, 2, "write: bresp=OKAY");
        chk(wr_data_valid == 1'b1, 2, "write: wr_data_valid pulsed");
        chk(wr_data == 32'hDEAD_BEEF, 2, "write: wr_data correct");

        // Accept B response
        @(negedge clk); s_axi_bready = 1'b1;
        @(posedge clk); #1;
        s_axi_bready = 1'b0;
        chk(s_axi_bvalid  == 1'b0, 2, "write: bvalid=0 after bready");
        chk(s_axi_awready == 1'b1, 2, "write: awready=1 back in IDLE");

        clk_cycle;

        // ===========================================================
        // T3: Read round-trip (AR → arbiter accept → rd_data → R OKAY)
        // ===========================================================

        // Present AR
        drive_ar(4'h2, 16'h2000);

        // DUT now in RS_ARB; rd_valid should be high
        chk(rd_valid == 1'b1, 3, "read: rd_valid=1 after AR accepted");
        chk(rd_addr  == 16'h2000, 3, "read: rd_addr correct");

        // Mock arbiter accepts the read request
        arb_accept_rd;

        // DUT in RS_DATA; rd_data_ready should be high
        chk(rd_data_ready == 1'b1, 3, "read: rd_data_ready=1");
        chk(rd_valid      == 1'b0, 3, "read: rd_valid deasserted");

        // Return read data (no ECC error)
        return_rd_data(32'hCAFE_F00D);

        // DUT in RS_RESP; rvalid should be asserted
        chk(s_axi_rvalid == 1'b1, 3, "read: rvalid=1");
        chk(s_axi_rdata  == 32'hCAFE_F00D, 3, "read: rdata correct");
        chk(s_axi_rresp  == 2'b00, 3, "read: rresp=OKAY");
        chk(s_axi_rlast  == 1'b1, 3, "read: rlast=1");

        // Accept R response
        @(negedge clk); s_axi_rready = 1'b1;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;
        chk(s_axi_rvalid  == 1'b0, 3, "read: rvalid=0 after rready");
        chk(s_axi_arready == 1'b1, 3, "read: arready=1 back in IDLE");

        clk_cycle;

        // ===========================================================
        // T4: Write ID forwarding – awid=0xA reflected in bid
        // ===========================================================

        drive_aw(4'hA, 16'h3000);
        drive_w(32'hAAAA_BBBB, 4'hF);
        arb_accept_wr;

        chk(s_axi_bid    == 4'hA, 4, "write-id: bid=0xA");
        chk(s_axi_bvalid == 1'b1, 4, "write-id: bvalid=1");

        @(negedge clk); s_axi_bready = 1'b1;
        @(posedge clk); #1;
        s_axi_bready = 1'b0;

        clk_cycle;

        // ===========================================================
        // T5: Read ID forwarding – arid=0xB reflected in rid
        // ===========================================================

        drive_ar(4'hB, 16'h4000);
        arb_accept_rd;
        return_rd_data(32'h1234_5678);

        chk(s_axi_rid    == 4'hB, 5, "read-id: rid=0xB");
        chk(s_axi_rvalid == 1'b1, 5, "read-id: rvalid=1");

        @(negedge clk); s_axi_rready = 1'b1;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;

        clk_cycle;

        // ===========================================================
        // T6: Back-pressure on B channel – hold bready=0 for 4 cycles
        // ===========================================================

        drive_aw(4'h3, 16'h5000);
        drive_w(32'hBEEF_CAFE, 4'hF);
        arb_accept_wr;

        // bvalid should be high; bready not yet asserted
        chk(s_axi_bvalid == 1'b1, 6, "b-backpressure: bvalid=1");

        // Hold bready=0 for 4 additional cycles
        repeat(4) begin
            clk_cycle;
            chk(s_axi_bvalid == 1'b1, 6, "b-backpressure: bvalid held");
        end

        // Now accept
        @(negedge clk); s_axi_bready = 1'b1;
        @(posedge clk); #1;
        s_axi_bready = 1'b0;
        chk(s_axi_bvalid == 1'b0, 6, "b-backpressure: bvalid=0 after accept");

        clk_cycle;

        // ===========================================================
        // T7: Back-pressure on R channel – hold rready=0 for 4 cycles
        // ===========================================================

        drive_ar(4'h4, 16'h6000);
        arb_accept_rd;
        return_rd_data(32'h5A5A_5A5A);

        // rvalid should be high; rready not yet asserted
        chk(s_axi_rvalid == 1'b1, 7, "r-backpressure: rvalid=1");

        // Hold rready=0 for 4 additional cycles
        repeat(4) begin
            clk_cycle;
            chk(s_axi_rvalid == 1'b1, 7, "r-backpressure: rvalid held");
        end

        // Now accept
        @(negedge clk); s_axi_rready = 1'b1;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;
        chk(s_axi_rvalid == 1'b0, 7, "r-backpressure: rvalid=0 after accept");

        clk_cycle;

        // ===========================================================
        // T8: SLVERR on double-bit ECC error
        // ===========================================================

        drive_ar(4'h5, 16'h7000);
        arb_accept_rd;

        // Return data with double-bit ECC error
        return_rd_data_dbe(32'hDEAD_C0DE);

        // DUT should set rresp = SLVERR (2'b10)
        chk(s_axi_rvalid == 1'b1, 8, "slverr: rvalid=1");
        chk(s_axi_rresp  == 2'b10, 8, "slverr: rresp=SLVERR");
        chk(s_axi_rid    == 4'h5, 8, "slverr: rid correct");

        @(negedge clk); s_axi_rready = 1'b1;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;

        clk_cycle;

        // ===========================================================
        // Summary
        // ===========================================================
        $display("--------------------------------------------");
        $display("axi4_slave_tb: %0d PASSED, %0d FAILED",
                 pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "axi4_slave_tb: simulation FAILED");
        $finish;
    end

endmodule
