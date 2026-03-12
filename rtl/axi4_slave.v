// axi4_slave.v – DDR4 AXI4 Subordinate Interface
//
// Accepts AXI4 write and read transactions, issues internal address
// requests to cmd_arbiter, and returns write responses / read data
// to the AXI4 master.
//
// Write path (single-beat, awlen=0):
//   WS_IDLE   – assert awready; latch AW when awvalid
//   WS_WAIT_W – assert wready;  latch W  when wvalid
//   WS_ARB    – hold wr_valid until wr_ready pulse from arbiter;
//               assert wr_data_valid one cycle after wr_ready
//   WS_RESP   – hold bvalid until bready from master
//
// Read path (single-beat):
//   RS_IDLE   – assert arready; latch AR when arvalid
//   RS_ARB    – hold rd_valid until rd_ready pulse from arbiter
//   RS_DATA   – assert rd_data_ready; wait for rd_data_valid
//   RS_RESP   – hold rvalid until rready from master;
//               rresp = SLVERR when rd_ecc_double_err is set
//
// AXI4 response codes: OKAY = 2'b00, SLVERR = 2'b10
// Reset: active-low asynchronous (negedge rst_n in sensitivity list).
//
// Compile & run:
//   iverilog -g2012 -o build/axi4_slave.out tb/axi4_slave_tb.v rtl/axi4_slave.v
//   vvp build/axi4_slave.out

`default_nettype none

module axi4_slave #(
    parameter AXI_ADDR_W = 34,
    parameter AXI_DATA_W = 64,
    parameter AXI_ID_W   = 8
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // ------------------------------------------------------------------
    // AXI4 Write Address channel
    // ------------------------------------------------------------------
    input  wire [AXI_ID_W-1:0]        s_axi_awid,
    input  wire [AXI_ADDR_W-1:0]      s_axi_awaddr,
    input  wire [7:0]                  s_axi_awlen,
    input  wire [2:0]                  s_axi_awsize,
    input  wire [1:0]                  s_axi_awburst,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,

    // ------------------------------------------------------------------
    // AXI4 Write Data channel
    // ------------------------------------------------------------------
    input  wire [AXI_DATA_W-1:0]      s_axi_wdata,
    input  wire [(AXI_DATA_W/8)-1:0]  s_axi_wstrb,
    input  wire                        s_axi_wlast,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,

    // ------------------------------------------------------------------
    // AXI4 Write Response channel
    // ------------------------------------------------------------------
    output reg  [AXI_ID_W-1:0]        s_axi_bid,
    output reg  [1:0]                  s_axi_bresp,
    output reg                         s_axi_bvalid,
    input  wire                        s_axi_bready,

    // ------------------------------------------------------------------
    // AXI4 Read Address channel
    // ------------------------------------------------------------------
    input  wire [AXI_ID_W-1:0]        s_axi_arid,
    input  wire [AXI_ADDR_W-1:0]      s_axi_araddr,
    input  wire [7:0]                  s_axi_arlen,
    input  wire [2:0]                  s_axi_arsize,
    input  wire [1:0]                  s_axi_arburst,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,

    // ------------------------------------------------------------------
    // AXI4 Read Data channel
    // ------------------------------------------------------------------
    output reg  [AXI_ID_W-1:0]        s_axi_rid,
    output reg  [AXI_DATA_W-1:0]      s_axi_rdata,
    output reg  [1:0]                  s_axi_rresp,
    output reg                         s_axi_rlast,
    output reg                         s_axi_rvalid,
    input  wire                        s_axi_rready,

    // ------------------------------------------------------------------
    // Internal: write address request to cmd_arbiter
    // ------------------------------------------------------------------
    output reg                         wr_valid,
    input  wire                        wr_ready,
    output reg  [AXI_ADDR_W-1:0]      wr_addr,
    output reg  [AXI_ID_W-1:0]        wr_id,

    // ------------------------------------------------------------------
    // Internal: read address request to cmd_arbiter
    // ------------------------------------------------------------------
    output reg                         rd_valid,
    input  wire                        rd_ready,
    output reg  [AXI_ADDR_W-1:0]      rd_addr,
    output reg  [AXI_ID_W-1:0]        rd_id,

    // ------------------------------------------------------------------
    // Write data path (to ECC encoder / write data buffer)
    // wr_data_valid is a one-cycle pulse coincident with wr_data/wr_strb
    // ------------------------------------------------------------------
    output reg  [AXI_DATA_W-1:0]      wr_data,
    output reg  [(AXI_DATA_W/8)-1:0]  wr_strb,
    output reg                         wr_data_valid,

    // ------------------------------------------------------------------
    // Read data path (from ECC decoder / read data buffer)
    // ------------------------------------------------------------------
    input  wire [AXI_DATA_W-1:0]      rd_data,
    input  wire                        rd_data_valid,
    input  wire                        rd_ecc_single_err,
    input  wire                        rd_ecc_double_err,
    output reg                         rd_data_ready
);

    // ================================================================
    // AXI4 response codes
    // ================================================================
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_SLVERR = 2'b10;

    // ================================================================
    // Write-path FSM state encodings
    // ================================================================
    localparam WS_IDLE   = 2'd0;  // accepting AW channel
    localparam WS_WAIT_W = 2'd1;  // AW captured, accepting W channel
    localparam WS_ARB    = 2'd2;  // issuing write request to arbiter
    localparam WS_RESP   = 2'd3;  // driving B-channel response

    // ================================================================
    // Read-path FSM state encodings
    // ================================================================
    localparam RS_IDLE = 2'd0;    // accepting AR channel
    localparam RS_ARB  = 2'd1;    // issuing read request to arbiter
    localparam RS_DATA = 2'd2;    // waiting for read data from DRAM
    localparam RS_RESP = 2'd3;    // driving R-channel response

    reg [1:0] wr_state;
    reg [1:0] rd_state;

    // Buffered write-address fields (held while waiting for W channel)
    reg [AXI_ID_W-1:0]   aw_id_buf;
    reg [AXI_ADDR_W-1:0] aw_addr_buf;

    // ================================================================
    // Combinational: AXI4 ready signals derived from FSM state
    // ================================================================
    assign s_axi_awready = (wr_state == WS_IDLE);
    assign s_axi_wready  = (wr_state == WS_WAIT_W);
    assign s_axi_arready = (rd_state == RS_IDLE);

    // ================================================================
    // Write-path FSM
    // ================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state      <= WS_IDLE;
            aw_id_buf     <= {AXI_ID_W{1'b0}};
            aw_addr_buf   <= {AXI_ADDR_W{1'b0}};
            wr_valid      <= 1'b0;
            wr_addr       <= {AXI_ADDR_W{1'b0}};
            wr_id         <= {AXI_ID_W{1'b0}};
            wr_data       <= {AXI_DATA_W{1'b0}};
            wr_strb       <= {(AXI_DATA_W/8){1'b0}};
            wr_data_valid <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bid     <= {AXI_ID_W{1'b0}};
            s_axi_bresp   <= RESP_OKAY;
        end else begin
            wr_data_valid <= 1'b0;  // default: cleared every cycle

            case (wr_state)

                // --------------------------------------------------------
                // IDLE: awready is asserted (combinational).
                // Latch AW fields when handshake occurs.
                // --------------------------------------------------------
                WS_IDLE: begin
                    if (s_axi_awvalid) begin
                        aw_id_buf   <= s_axi_awid;
                        aw_addr_buf <= s_axi_awaddr;
                        wr_state    <= WS_WAIT_W;
                    end
                end

                // --------------------------------------------------------
                // WAIT_W: wready is asserted (combinational).
                // Latch W data and issue request to arbiter when valid.
                // --------------------------------------------------------
                WS_WAIT_W: begin
                    if (s_axi_wvalid) begin
                        wr_valid <= 1'b1;
                        wr_addr  <= aw_addr_buf;
                        wr_id    <= aw_id_buf;
                        wr_data  <= s_axi_wdata;
                        wr_strb  <= s_axi_wstrb;
                        wr_state <= WS_ARB;
                    end
                end

                // --------------------------------------------------------
                // ARB: hold wr_valid until arbiter pulses wr_ready.
                // On acceptance: pulse wr_data_valid and send B response.
                // --------------------------------------------------------
                WS_ARB: begin
                    if (wr_ready) begin
                        wr_valid      <= 1'b0;
                        wr_data_valid <= 1'b1;   // one-cycle write-data strobe
                        s_axi_bvalid  <= 1'b1;
                        s_axi_bid     <= wr_id;
                        s_axi_bresp   <= RESP_OKAY;
                        wr_state      <= WS_RESP;
                    end
                end

                // --------------------------------------------------------
                // RESP: hold bvalid until master asserts bready.
                // --------------------------------------------------------
                WS_RESP: begin
                    if (s_axi_bready) begin
                        s_axi_bvalid <= 1'b0;
                        wr_state     <= WS_IDLE;
                    end
                end

                default: wr_state <= WS_IDLE;
            endcase
        end
    end

    // ================================================================
    // Read-path FSM
    // ================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state      <= RS_IDLE;
            rd_valid      <= 1'b0;
            rd_addr       <= {AXI_ADDR_W{1'b0}};
            rd_id         <= {AXI_ID_W{1'b0}};
            rd_data_ready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rid     <= {AXI_ID_W{1'b0}};
            s_axi_rdata   <= {AXI_DATA_W{1'b0}};
            s_axi_rresp   <= RESP_OKAY;
            s_axi_rlast   <= 1'b0;
        end else begin
            case (rd_state)

                // --------------------------------------------------------
                // IDLE: arready is asserted (combinational).
                // Latch AR fields when handshake occurs.
                // --------------------------------------------------------
                RS_IDLE: begin
                    if (s_axi_arvalid) begin
                        rd_addr  <= s_axi_araddr;
                        rd_id    <= s_axi_arid;
                        rd_valid <= 1'b1;
                        rd_state <= RS_ARB;
                    end
                end

                // --------------------------------------------------------
                // ARB: hold rd_valid until arbiter pulses rd_ready.
                // --------------------------------------------------------
                RS_ARB: begin
                    if (rd_ready) begin
                        rd_valid      <= 1'b0;
                        rd_data_ready <= 1'b1;
                        rd_state      <= RS_DATA;
                    end
                end

                // --------------------------------------------------------
                // DATA: rd_data_ready asserted; wait for rd_data_valid.
                // Latch data and ECC flags, then drive R channel.
                // --------------------------------------------------------
                RS_DATA: begin
                    if (rd_data_valid) begin
                        rd_data_ready <= 1'b0;
                        s_axi_rid     <= rd_id;
                        s_axi_rdata   <= rd_data;
                        s_axi_rresp   <= rd_ecc_double_err ? RESP_SLVERR
                                                            : RESP_OKAY;
                        s_axi_rlast   <= 1'b1;
                        s_axi_rvalid  <= 1'b1;
                        rd_state      <= RS_RESP;
                    end
                end

                // --------------------------------------------------------
                // RESP: hold rvalid until master asserts rready.
                // --------------------------------------------------------
                RS_RESP: begin
                    if (s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        s_axi_rlast  <= 1'b0;
                        rd_state     <= RS_IDLE;
                    end
                end

                default: rd_state <= RS_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
