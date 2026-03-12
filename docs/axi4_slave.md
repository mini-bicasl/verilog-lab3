# axi4_slave

## Overview

`axi4_slave` is the AXI4 subordinate (slave) interface of the DDR4 controller.
It receives read and write transactions from an AXI4 master (CPU, DMA, NoC),
converts them into internal address requests for `cmd_arbiter`, manages the
write data path to the ECC encoder, and returns read data (with corrected ECC
status) back to the master via the R channel.

It sits at the top of the datapath described in
[docs/ARCHITECTURE.md](ARCHITECTURE.md) §2:

```
AXI4 Master → axi4_slave → cmd_arbiter → cmd_scheduler → ...
```

---

## Interface

### Parameters

| Parameter    | Default | Description |
|---|---|---|
| `AXI_ADDR_W` | 34 | AXI address width (bits) |
| `AXI_DATA_W` | 64 | AXI data width (bits; must be a power of 2) |
| `AXI_ID_W`   | 8  | AXI transaction ID width (bits) |

### Ports

#### Clock and Reset

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low asynchronous reset |

#### AXI4 Write Address Channel

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_awid` | in | AXI_ID_W | Write address ID |
| `s_axi_awaddr` | in | AXI_ADDR_W | Write address (byte-addressed) |
| `s_axi_awlen` | in | 8 | Burst length minus 1 (AXI4) |
| `s_axi_awsize` | in | 3 | Transfer size |
| `s_axi_awburst` | in | 2 | Burst type |
| `s_axi_awvalid` | in | 1 | Write address valid |
| `s_axi_awready` | out | 1 | Write address ready (combinational, high in WS_IDLE) |

#### AXI4 Write Data Channel

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_wdata` | in | AXI_DATA_W | Write data |
| `s_axi_wstrb` | in | AXI_DATA_W/8 | Write byte strobes |
| `s_axi_wlast` | in | 1 | Last beat of write burst |
| `s_axi_wvalid` | in | 1 | Write data valid |
| `s_axi_wready` | out | 1 | Write data ready (combinational, high in WS_WAIT_W) |

#### AXI4 Write Response Channel

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_bid` | out | AXI_ID_W | Write response ID (mirrors `awid`) |
| `s_axi_bresp` | out | 2 | Write response: `OKAY (2'b00)` always |
| `s_axi_bvalid` | out | 1 | Write response valid |
| `s_axi_bready` | in | 1 | Write response ready |

#### AXI4 Read Address Channel

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_arid` | in | AXI_ID_W | Read address ID |
| `s_axi_araddr` | in | AXI_ADDR_W | Read address |
| `s_axi_arlen` | in | 8 | Burst length minus 1 |
| `s_axi_arsize` | in | 3 | Transfer size |
| `s_axi_arburst` | in | 2 | Burst type |
| `s_axi_arvalid` | in | 1 | Read address valid |
| `s_axi_arready` | out | 1 | Read address ready (combinational, high in RS_IDLE) |

#### AXI4 Read Data Channel

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_rid` | out | AXI_ID_W | Read data ID (mirrors `arid`) |
| `s_axi_rdata` | out | AXI_DATA_W | Read data (ECC-corrected) |
| `s_axi_rresp` | out | 2 | Read response: `OKAY (2'b00)` or `SLVERR (2'b10)` on double-bit ECC error |
| `s_axi_rlast` | out | 1 | Last beat of read burst (always 1 for single-beat) |
| `s_axi_rvalid` | out | 1 | Read data valid |
| `s_axi_rready` | in | 1 | Read data ready |

#### Internal: Write Request to `cmd_arbiter`

| Port | Dir | Width | Description |
|---|---|---|---|
| `wr_valid` | out | 1 | Write address request valid |
| `wr_ready` | in | 1 | Write request accepted (1-cycle pulse from arbiter) |
| `wr_addr` | out | AXI_ADDR_W | Write address |
| `wr_id` | out | AXI_ID_W | Write transaction ID |

#### Internal: Read Request to `cmd_arbiter`

| Port | Dir | Width | Description |
|---|---|---|---|
| `rd_valid` | out | 1 | Read address request valid |
| `rd_ready` | in | 1 | Read request accepted (1-cycle pulse from arbiter) |
| `rd_addr` | out | AXI_ADDR_W | Read address |
| `rd_id` | out | AXI_ID_W | Read transaction ID |

#### Write Data Path (to ECC Encoder / Write Buffer)

| Port | Dir | Width | Description |
|---|---|---|---|
| `wr_data` | out | AXI_DATA_W | Write data (latched from AXI W channel) |
| `wr_strb` | out | AXI_DATA_W/8 | Write byte strobes |
| `wr_data_valid` | out | 1 | One-cycle pulse: write data available for ECC encoding |

#### Read Data Path (from ECC Decoder / Read Buffer)

| Port | Dir | Width | Description |
|---|---|---|---|
| `rd_data` | in | AXI_DATA_W | Corrected read data from ECC decoder |
| `rd_data_valid` | in | 1 | Read data available |
| `rd_ecc_single_err` | in | 1 | Single-bit error corrected (informational) |
| `rd_ecc_double_err` | in | 1 | Double-bit error detected; causes `rresp = SLVERR` |
| `rd_data_ready` | out | 1 | Slave ready to accept read data |

---

## Control Flow

### Write FSM

```
         rst_n = 0
              |
              v
        +----------+  awvalid   +------------+
        |  WS_IDLE |----------->| WS_WAIT_W  |
        |          |            |            |
        | awready=1|            | wready=1   |
        +----------+            +-----+------+
              ^                       | wvalid
              |                       v
              |                 +----------+
              |                 |  WS_ARB  |  wr_valid=1
              |                 +-----+----+
              |                       | wr_ready (pulse)
              |                       v
              |                 +----------+
              +-----------------|  WS_RESP |  bvalid=1
                     bready     +----------+
```

State descriptions:

| State | `awready` | `wready` | Action |
|---|---|---|---|
| `WS_IDLE` | 1 | 0 | Accept AW channel; buffer `awid`, `awaddr` |
| `WS_WAIT_W` | 0 | 1 | Accept W channel; latch `wdata`, `wstrb`; assert `wr_valid` |
| `WS_ARB` | 0 | 0 | Hold `wr_valid` until `wr_ready` pulse; then assert `bvalid`, pulse `wr_data_valid` |
| `WS_RESP` | 0 | 0 | Hold `bvalid`; on `bready` → return to WS_IDLE |

### Read FSM

```
         rst_n = 0
              |
              v
        +----------+  arvalid   +----------+
        |  RS_IDLE |----------->|  RS_ARB  |  rd_valid=1
        |          |            +----+-----+
        | arready=1|                 | rd_ready (pulse)
        +----------+                 v
              ^               +----------+
              |               |  RS_DATA |  rd_data_ready=1
              |               +----+-----+
              |                    | rd_data_valid
              |                    v
              |               +----------+
              +---------------|  RS_RESP |  rvalid=1, rlast=1
                    rready     +----------+
```

State descriptions:

| State | `arready` | `rd_data_ready` | Action |
|---|---|---|---|
| `RS_IDLE` | 1 | 0 | Accept AR channel; buffer `arid`, `araddr`; assert `rd_valid` |
| `RS_ARB` | 0 | 0 | Hold `rd_valid` until `rd_ready` pulse from arbiter |
| `RS_DATA` | 0 | 1 | Wait for `rd_data_valid`; latch `rd_data` and ECC flags |
| `RS_RESP` | 0 | 0 | Drive `rvalid`, `rdata`, `rresp`, `rlast`; on `rready` → RS_IDLE |

### ECC Error Handling

When `rd_ecc_double_err` is high at the moment `rd_data_valid` is sampled,
the module sets `s_axi_rresp = 2'b10` (SLVERR) to signal an uncorrectable
error to the AXI master.  Single-bit errors (`rd_ecc_single_err`) are silently
corrected by the ECC decoder and `rresp` remains OKAY.

---

## Constraints and Assumptions

- **Single-beat transactions** – this implementation handles `awlen=0` and
  `arlen=0` (one data beat per transaction).  Multi-beat burst support requires
  extending the write and read FSMs with beat counters.
- **AW before W** – the write-path FSM accepts the AW channel first, then the
  W channel.  Per AXI4 spec, W may arrive before AW, but this implementation
  does not buffer W-before-AW.
- **B response timing** – `bvalid` is asserted immediately when the arbiter
  accepts the write address (optimistic response).  The actual DRAM write
  completes asynchronously via `cmd_scheduler` and `phy_if`.
- **Ready signals are combinational** – `awready`, `wready`, and `arready` are
  wire outputs driven by `assign` statements derived from the FSM state register.
  There is no registered pipeline bubble on the ready path.
- **Reset** – active-low asynchronous reset (`rst_n`); both FSMs return to
  their IDLE states and all outputs are de-asserted.

---

## Files

| File | Description |
|---|---|
| `rtl/axi4_slave.v` | Synthesizable RTL |
| `tb/axi4_slave_tb.v` | Directed unit testbench |
| `results/phase-ddr4-axi/axi4_slave_result.json` | Simulation result summary |
| `results/phase-ddr4-axi/axi4_slave_sim.log` | Simulation output log |
| `results/phase-ddr4-axi/axi4_slave.vcd` | Waveform dump |
