# phy_if

## Overview

`phy_if` is the DDR4 PHY interface module of the DDR4 controller.  It sits
between the controller core (`cmd_scheduler`, write buffer, read buffer) and the
physical DRAM pads.  The module provides:

- **DDR4 command bus output** – translates internal command codes (ACT/RD/WR/PRE/REF/NOP)
  into the DDR4-standard `ACT_n`, `RAS_n`/A16, `CAS_n`/A15, `WE_n`/A14 pin encodings.
- **DQ / DQS bidir direction control** – drives `ddr4_dq` and `ddr4_dqs_p/n`
  during writes; places them in Hi-Z during reads so the DRAM can drive them.
- **DQS write preamble** – holds DQS_p low for one controller clock before the
  first DQS toggle, per JEDEC DDR4 §3.7.
- **DQS write burst** – DQS_p toggles every controller clock during the P_TBURST
  write burst window (half-rate domain: 1 clk = 2 DRAM bit-times).
- **DQS write postamble** – holds DQS_p low for one controller clock after the
  last DQS toggle.
- **Read data capture** – counts P_TCL controller clocks from a RD command, then
  samples `ddr4_dq` / `ddr4_dm_dbi_n` and asserts `rd_data_valid` for one cycle.
- **Write-leveling calibration mode** – drives DQS continuously and counts a
  simulated calibration period, then asserts `wl_done`.

Vendor-specific DLL/PLL calibration is out of scope; this module provides the
RTL wrapper logic described in `docs/ARCHITECTURE.md` §8 Note 1.

It connects at the bottom of the datapath:

```
cmd_scheduler → phy_if → DDR4 DRAM pads (DQ, DQS, CMD, ADDR)
```

---

## Interface

### Parameters

| Parameter    | Default | Description |
|---|---|---|
| `RANKS`      | 1  | Number of DRAM ranks |
| `DQ_WIDTH`   | 64 | DQ bus width (bits) |
| `DQS_WIDTH`  | 8  | Number of differential DQS pairs |
| `DM_WIDTH`   | 8  | DM/DBI_n bus width |
| `ROW_ADDR_W` | 17 | Row address width |
| `COL_ADDR_W` | 10 | Column address width |
| `P_TCL`      | 11 | CAS latency (controller clocks) |
| `P_TCWL`     | 9  | CAS write latency (controller clocks, ≥ 2) |
| `P_TBURST`   | 4  | Write burst duration in controller clocks (= BL8 / 2) |

### Ports

#### Clock and Reset

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk`   | in | 1 | System clock (half DRAM data-rate) |
| `rst_n` | in | 1 | Active-low asynchronous reset |

#### Controller-Facing Command Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `ctrl_cmd`       | in | 3 | Command code: NOP/ACT/RD/WR/PRE/REF |
| `ctrl_bg`        | in | 2 | Bank group |
| `ctrl_ba`        | in | 2 | Bank address |
| `ctrl_addr`      | in | ROW_ADDR_W | Row / column address |
| `ctrl_cmd_valid` | in | 1 | Command valid this cycle |

#### Write Data Path (from write buffer / ECC encoder)

| Port | Dir | Width | Description |
|---|---|---|---|
| `wr_dq`        | in | DQ_WIDTH | 64-bit write data |
| `wr_dm`        | in | DM_WIDTH | 8-bit data mask / ECC check bits |
| `wr_data_valid`| in | 1 | Latch `wr_dq`/`wr_dm` this cycle |

#### Read Data Path (to ECC decoder / read buffer)

| Port | Dir | Width | Description |
|---|---|---|---|
| `rd_dq`        | out | DQ_WIDTH | Captured 64-bit read data |
| `rd_dm`        | out | DM_WIDTH | Captured DM/DBI bits |
| `rd_data_valid`| out | 1 | 1-cycle pulse: `rd_dq`/`rd_dm` are valid |

#### Calibration and Initialization

| Port | Dir | Width | Description |
|---|---|---|---|
| `wl_mode`   | in  | 1 | Assert to enter write-leveling mode |
| `wl_done`   | out | 1 | Write leveling complete (stays high until `wl_mode` deasserted) |
| `init_done` | in  | 1 | DRAM initialisation complete; enables CKE and deasserts CS_n |

#### Debug / Status

| Port | Dir | Width | Description |
|---|---|---|---|
| `dq_oe`  | out | 1 | 1 = DQ bus currently driven by controller |
| `dqs_oe` | out | 1 | 1 = DQS bus currently driven by controller |

#### DDR4 DRAM Pins

| Port | Dir | Width | Description |
|---|---|---|---|
| `ddr4_ck_p/n`    | out   | RANKS     | Differential clock (mirrors `clk`) |
| `ddr4_cke`       | out   | RANKS     | Clock enable; asserted when `init_done` |
| `ddr4_cs_n`      | out   | RANKS     | Chip select (active-low); deasserted when `rst_n & init_done` |
| `ddr4_act_n`     | out   | 1         | Activate indicator |
| `ddr4_ras_n`     | out   | 1         | RAS / A16 (registered) |
| `ddr4_cas_n`     | out   | 1         | CAS / A15 (registered) |
| `ddr4_we_n`      | out   | 1         | WE / A14 (registered) |
| `ddr4_ba`        | out   | 2         | Bank address (registered) |
| `ddr4_bg`        | out   | 2         | Bank group (registered) |
| `ddr4_addr`      | out   | ROW_ADDR_W| Row / column multiplexed address (registered) |
| `ddr4_odt`       | out   | RANKS     | On-die termination (tied 0 in this model) |
| `ddr4_reset_n`   | out   | 1         | DRAM reset (mirrors `rst_n`) |
| `ddr4_dq`        | inout | DQ_WIDTH  | Data bus (driven during writes, Hi-Z during reads) |
| `ddr4_dqs_p/n`   | inout | DQS_WIDTH | Differential data strobes (driven during writes) |
| `ddr4_dm_dbi_n`  | inout | DM_WIDTH  | Data mask / ECC byte (driven during writes) |

---

## Control Flow

### Write Burst FSM

```
           rst_n = 0
                |
                v
          +----------+  CMD_WR  +----------+
          |  WR_IDLE |--------->|  WR_CWL  |  count P_TCWL-1 clocks
          +----------+          +-----+----+
                ^                     | cnt=0
                |                     v
                |               +----------+
                |               |  WR_PRE  |  register dq_oe=1, dqs_p=0
                |               +-----+----+  (outputs visible next clock)
                |                     |
                |                     v
                |               +----------+
                |               |  WR_DATA |  DQS_p toggles; DQ driven
                |               |          |  P_TBURST clocks
                |               +-----+----+
                |                     | cnt=0
                |                     v
                |               +----------+
                +---------------|  WR_POST |  dq_oe→0, dqs_oe→0 next clock
                                +----------+  (DQS_p=0 still visible 1 cycle)
```

State descriptions:

| State | `dq_oe` | `dqs_oe` | DQS_p | Notes |
|---|---|---|---|---|
| `WR_IDLE`  | 0 | 0 | Hi-Z | Waiting for CMD_WR |
| `WR_CWL`   | 0 | 0 | Hi-Z | Counting P_TCWL − 1 clocks |
| `WR_PRE`   | 0→1 | 0→1 | 0 (registered) | Preamble values latched; visible next clock |
| `WR_DATA`  | 1 | 1 | toggles | DQS_p alternates 0/1 each controller clock |
| `WR_POST`  | 1→0 | 1→0 | 0 (last toggle) | Postamble: DQS_p=0 visible; OE released next clock |

**Registered-output timing note:** All `dq_oe`, `dqs_oe`, and `dqs_p_out_r`
assignments are non-blocking (`<=`).  Values set in state S become visible to
external logic on the clock *after* S is the active state.  The preamble
(DQS_p = 0) therefore appears one clock after `WR_PRE` runs, which is the
first clock of `WR_DATA`.

### DQS Waveform (P_TBURST = 4, relative to WR command)

```
Clock:   T  T+1  T+2  T+3  T+4  T+5  T+6  T+7  T+8  T+9 T+10
State: IDLE CWL  CWL  CWL  PRE  DAT  DAT  DAT  DAT  PST IDLE
DQS_p:   Z    Z    Z    Z    Z    0    1    0    1    0    Z
          ← CWL →          |pre|← burst (4 clk) →|pst|
```

Legend: Z = Hi-Z, pre = preamble, pst = postamble

### Read Data Capture

When `ctrl_cmd = CMD_RD` and `ctrl_cmd_valid = 1`:
1. `rd_cnt` is loaded with `P_TCL − 1`.
2. Each clock `rd_cnt` decrements.
3. When `rd_cnt` reaches 0, `ddr4_dq` and `ddr4_dm_dbi_n` are sampled and
   `rd_data_valid` is pulsed for one clock.

The DQ/DQS pads remain Hi-Z throughout the read latency window (DRAM drives
them via its internal output path).

### DDR4 Command Bus Encoding

| `ctrl_cmd` | `act_n` | `ras_n` | `cas_n` | `we_n` |
|---|---|---|---|---|
| NOP | 1 | 1 | 1 | 1 |
| ACT | 0 | 1 | 1 | 1 |
| RD  | 1 | 1 | 0 | 1 |
| WR  | 1 | 1 | 0 | 0 |
| PRE | 1 | 0 | 1 | 0 |
| REF | 1 | 0 | 0 | 1 |

All command pins are registered (updated on posedge `clk`).  A NOP is driven
when `ctrl_cmd_valid = 0`.

### Write-Leveling Mode

When `wl_mode = 1`:
- DQS is driven continuously (`dqs_oe` asserted).
- A counter runs for `WL_CALIB_CYCLES` (8) clocks.
- `wl_done` is asserted on completion and remains high until `wl_mode` is
  deasserted, at which point `wl_done` clears and the counter resets.

---

## Constraints and Assumptions

- **Half-rate domain** – one controller clock = two DRAM bit-times.  DQS
  toggles every controller clock during the burst, modelling the full-rate
  strobe.
- **Fixed CWL / CL latency** – timing parameters (`P_TCWL`, `P_TCL`) are
  compile-time constants; runtime training is not supported.
- **Single-cycle write data** – `wr_dq`/`wr_dm` are latched when
  `wr_data_valid = 1` and held through the entire burst.  Sub-word writes
  using different data per DQS cycle are not supported.
- **Read capture model** – a fixed `P_TCL` delay models the DQS capture path.
  In a real design, DQS-edge-triggered flip-flops (IDELAY / ISERDES) are used.
- **No power-down / ODT** – `ddr4_odt` is tied to 0; self-refresh and ODT
  training are out of scope.

---

## Files

| File | Description |
|---|---|
| `rtl/phy_if.v` | Synthesizable RTL |
| `tb/phy_if_tb.v` | Directed unit testbench (10 test groups) |
| `results/phase-ddr4-phy/phy_if_result.json` | Simulation result summary |
| `results/phase-ddr4-phy/phy_if_sim.log` | Simulation output log |
| `results/phase-ddr4-phy/phy_if.vcd` | Waveform dump |
