// cmd_arbiter_tb.v – Testbench for cmd_arbiter
//
// Uses compact parameters:
//   AXI_ADDR_W = 10 (narrow address to keep stimulus readable)
//   AXI_ID_W   = 4
//   RD_PRIORITY = 1 (reads preferred over writes)
//
// Tests:
//   T1:  Reset – arb_valid=0, rd_ready=0, wr_ready=0, state=IDLE
//   T2:  Read-only: rd_valid=1, wr_valid=0 → grant read, rd_ready pulse
//   T3:  Write-only: wr_valid=1, rd_valid=0 → grant write, wr_ready pulse
//   T4:  Both valid with RD_PRIORITY=1 → reads win; then wr granted
//   T5:  ref_req asserted → no new grants; backlog granted after deassert
//   T6:  Back-pressure: arb_ready=0 → arb_valid held; accepted when ready=1
//   T7:  Sequential pipeline: back-to-back read requests each granted
//   T8:  ref_req deasserted mid-BUSY: in-flight completes, new grant accepted
//
// Compile & run:
//   iverilog -g2012 -o build/cmd_arbiter.out tb/cmd_arbiter_tb.v rtl/cmd_arbiter.v
//   vvp build/cmd_arbiter.out

`timescale 1ns/1ps

module cmd_arbiter_tb;

    // ----------------------------------------------------------------
    // Parameters
    // ----------------------------------------------------------------
    localparam AXI_ADDR_W  = 10;
    localparam AXI_ID_W    = 4;
    localparam RD_PRIORITY = 1;

    // ----------------------------------------------------------------
    // DUT ports
    // ----------------------------------------------------------------
    reg                   clk;
    reg                   rst_n;
    reg                   ref_req;

    reg                   rd_valid;
    wire                  rd_ready;
    reg  [AXI_ADDR_W-1:0] rd_addr;
    reg  [AXI_ID_W-1:0]   rd_id;

    reg                   wr_valid;
    wire                  wr_ready;
    reg  [AXI_ADDR_W-1:0] wr_addr;
    reg  [AXI_ID_W-1:0]   wr_id;

    wire                  arb_valid;
    reg                   arb_ready;
    wire                  arb_is_write;
    wire [AXI_ADDR_W-1:0] arb_addr;
    wire [AXI_ID_W-1:0]   arb_id;

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    cmd_arbiter #(
        .AXI_ADDR_W  (AXI_ADDR_W),
        .AXI_ID_W    (AXI_ID_W),
        .RD_PRIORITY (RD_PRIORITY)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .ref_req     (ref_req),
        .rd_valid    (rd_valid),
        .rd_ready    (rd_ready),
        .rd_addr     (rd_addr),
        .rd_id       (rd_id),
        .wr_valid    (wr_valid),
        .wr_ready    (wr_ready),
        .wr_addr     (wr_addr),
        .wr_id       (wr_id),
        .arb_valid   (arb_valid),
        .arb_ready   (arb_ready),
        .arb_is_write(arb_is_write),
        .arb_addr    (arb_addr),
        .arb_id      (arb_id)
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
        $dumpfile("results/phase-ddr4-sched/cmd_arbiter.vcd");
        $dumpvars(0, cmd_arbiter_tb);
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
                $display("FAIL T%0d: %s  (arb_valid=%b is_wr=%b addr=%h id=%h)",
                         tid, msg, arb_valid, arb_is_write, arb_addr, arb_id);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Advance one clock cycle
    task clk_cycle;
        begin
            @(posedge clk); #1;
        end
    endtask

    // Accept downstream command on the same cycle arb_valid is seen
    task accept_now;
        begin
            @(negedge clk); arb_ready = 1'b1;
            @(posedge clk); #1;
            arb_ready = 1'b0;
        end
    endtask

    // ----------------------------------------------------------------
    // Main test sequencer
    // ----------------------------------------------------------------
    initial begin
        pass_count = 0;
        fail_count = 0;

        // Default stimulus
        rst_n     = 1'b0;
        ref_req   = 1'b0;
        rd_valid  = 1'b0;
        rd_addr   = {AXI_ADDR_W{1'b0}};
        rd_id     = {AXI_ID_W{1'b0}};
        wr_valid  = 1'b0;
        wr_addr   = {AXI_ADDR_W{1'b0}};
        wr_id     = {AXI_ID_W{1'b0}};
        arb_ready = 1'b0;

        // =============================================================
        // T1: Reset state
        // =============================================================
        repeat(4) @(posedge clk);
        #1;
        chk(arb_valid   == 1'b0, 1, "reset: arb_valid=0");
        chk(rd_ready    == 1'b0, 1, "reset: rd_ready=0");
        chk(wr_ready    == 1'b0, 1, "reset: wr_ready=0");
        chk(arb_is_write == 1'b0, 1, "reset: arb_is_write=0");

        @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // =============================================================
        // T2: Read-only request
        // =============================================================
        @(negedge clk);
        rd_valid = 1'b1;
        rd_addr  = 10'h0A5;
        rd_id    = 4'h3;

        // arb_ready=0: grant should appear but stall until ready
        @(posedge clk); #1;
        chk(arb_valid    == 1'b1, 2, "rd-only: arb_valid=1 after 1 cycle");
        chk(arb_is_write == 1'b0, 2, "rd-only: arb_is_write=0");
        chk(arb_addr     == 10'h0A5, 2, "rd-only: arb_addr correct");
        chk(arb_id       == 4'h3,    2, "rd-only: arb_id correct");
        chk(rd_ready     == 1'b1, 2, "rd-only: rd_ready pulsed");

        rd_valid = 1'b0;
        // Accept it now
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;
        chk(arb_valid == 1'b0, 2, "rd-only: arb_valid cleared after accept");

        clk_cycle;

        // =============================================================
        // T3: Write-only request
        // =============================================================
        @(negedge clk);
        wr_valid = 1'b1;
        wr_addr  = 10'h1BC;
        wr_id    = 4'h7;

        @(posedge clk); #1;
        chk(arb_valid    == 1'b1, 3, "wr-only: arb_valid=1");
        chk(arb_is_write == 1'b1, 3, "wr-only: arb_is_write=1");
        chk(arb_addr     == 10'h1BC, 3, "wr-only: arb_addr correct");
        chk(wr_ready     == 1'b1, 3, "wr-only: wr_ready pulsed");
        chk(rd_ready     == 1'b0, 3, "wr-only: rd_ready not asserted");

        wr_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        clk_cycle;

        // =============================================================
        // T4: Both valid with RD_PRIORITY=1 – reads win
        // =============================================================
        @(negedge clk);
        rd_valid = 1'b1;
        rd_addr  = 10'h0F0;
        rd_id    = 4'h1;
        wr_valid = 1'b1;
        wr_addr  = 10'h0FF;
        wr_id    = 4'h2;

        @(posedge clk); #1;
        chk(arb_is_write == 1'b0,   4, "both-valid RD_PRI=1: read granted");
        chk(arb_addr     == 10'h0F0,4, "both-valid: rd_addr forwarded");
        chk(rd_ready     == 1'b1,   4, "both-valid: rd_ready pulsed");
        chk(wr_ready     == 1'b0,   4, "both-valid: wr_ready NOT pulsed");

        // Accept read; now write should be granted on next idle cycle
        rd_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        // Wait one more cycle for the write to be scheduled
        @(posedge clk); #1;
        chk(arb_valid    == 1'b1, 4, "both-valid: write granted next");
        chk(arb_is_write == 1'b1, 4, "both-valid: is_write=1 for write");
        chk(arb_addr     == 10'h0FF, 4, "both-valid: wr_addr forwarded");

        wr_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        clk_cycle;

        // =============================================================
        // T5: ref_req blocks arbitration
        // =============================================================
        @(negedge clk);
        ref_req  = 1'b1;
        rd_valid = 1'b1;
        rd_addr  = 10'h077;
        rd_id    = 4'h5;

        repeat(3) clk_cycle;
        chk(arb_valid == 1'b0, 5, "ref_req: no grant while ref_req=1");
        chk(rd_ready  == 1'b0, 5, "ref_req: rd_ready stays 0");

        // Release ref_req; request should now be granted
        @(negedge clk); ref_req = 1'b0;
        @(posedge clk); #1;
        chk(arb_valid    == 1'b1, 5, "ref_req released: grant issued");
        chk(arb_is_write == 1'b0, 5, "ref_req released: is read");

        rd_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        clk_cycle;

        // =============================================================
        // T6: Back-pressure: arb_ready=0 holds arb_valid
        // =============================================================
        @(negedge clk);
        wr_valid = 1'b1;
        wr_addr  = 10'h0CC;
        wr_id    = 4'hA;

        @(posedge clk); #1;
        chk(arb_valid == 1'b1, 6, "backpressure: arb_valid asserted");

        // Hold arb_ready=0 for 3 more cycles – arb_valid must stay high
        repeat(3) begin
            clk_cycle;
            chk(arb_valid == 1'b1, 6, "backpressure: arb_valid held high");
        end

        // Now accept
        wr_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;
        chk(arb_valid == 1'b0, 6, "backpressure: arb_valid deasserted after accept");

        clk_cycle;

        // =============================================================
        // T7: Sequential pipeline – two back-to-back read requests
        // =============================================================
        @(negedge clk);
        rd_valid = 1'b1;
        rd_addr  = 10'h011;
        rd_id    = 4'hB;

        @(posedge clk); #1;
        chk(arb_valid == 1'b1, 7, "pipeline req1: arb_valid=1");
        chk(arb_addr  == 10'h011, 7, "pipeline req1: addr correct");

        // Accept req1; present req2 simultaneously
        rd_addr = 10'h022;
        rd_id   = 4'hC;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        // After accepting req1, req2 should be picked up next cycle
        @(posedge clk); #1;
        chk(arb_valid == 1'b1, 7, "pipeline req2: arb_valid=1");
        chk(arb_addr  == 10'h022, 7, "pipeline req2: addr correct");

        rd_valid = 1'b0;
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;

        clk_cycle;

        // =============================================================
        // T8: ref_req during BUSY does not abort in-flight transaction
        // =============================================================
        @(negedge clk);
        rd_valid = 1'b1;
        rd_addr  = 10'h033;

        @(posedge clk); #1;
        chk(arb_valid == 1'b1, 8, "in-flight: arb_valid asserted");

        // Assert ref_req while arb is BUSY
        @(negedge clk); ref_req = 1'b1; arb_ready = 1'b0; rd_valid = 1'b0;
        clk_cycle;
        chk(arb_valid == 1'b1, 8, "in-flight+ref_req: arb_valid still high");

        // Complete the in-flight transaction despite ref_req
        @(negedge clk); arb_ready = 1'b1;
        @(posedge clk); #1;
        arb_ready = 1'b0;
        chk(arb_valid == 1'b0, 8, "in-flight: cleared after accept");

        ref_req = 1'b0;
        clk_cycle;

        // =============================================================
        // Summary
        // =============================================================
        $display("--------------------------------------------");
        $display("cmd_arbiter_tb: %0d PASSED, %0d FAILED",
                 pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "cmd_arbiter_tb: simulation FAILED");
        $finish;
    end

endmodule
