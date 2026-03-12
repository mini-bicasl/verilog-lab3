# DDR4 Controller Architecture

> **Authoritative design reference** – all RTL, testbenches, and documentation must
> be consistent with this file.  Target standard: **JEDEC JESD79-4B (DDR4)**.

---

## 1. Project Overview

This project implements a **commercial server-grade DDR4 SDRAM controller** in
synthesizable Verilog (IEEE 1364-2005 / IEEE 1800-2012).  The controller sits
between an AXI4 host interface and one or more DDR4 DRAM ranks and provides:

| Capability | Details |
|---|---|
| **Bus width** | x72 (64-bit data + 8-bit ECC) per channel |
| **ECC** | Single-Error Correction, Double-Error Detection (SECDED, Hamming-based) |
| **Refresh** | Auto-refresh (REFab) and per-bank refresh (REFpb) per JEDEC DDR4 |
| **Timing** | All JEDEC timing parameters are compile-time configurable via `parameters` |
| **Ranks** | Up to 2 ranks per channel (extensible) |
| **Burst length** | BL8 fixed; BL4 On-the-Fly (OTF) optional |
| **Data rates** | DDR4-2133 through DDR4-3200 (tCK configurable) |
| **Host interface** | AXI4 subordinate (ID width configurable) |

The design targets an FPGA or ASIC flow and is **fully synchronous** with a
single system clock (`clk`) and active-low reset (`rst_n`).

---

## 2. Functional Blocks / Modules

```
+--------------------------------------------------------------+
|                     ddr4_ctrl_top                            |
|                                                              |
|  +-------------+   +--------------+   +------------------+  |
|  |  axi4_slave |-->|  cmd_arbiter |-->|  cmd_scheduler   |  |
|  +-------------+   +--------------+   +--------+---------+  |
|                                                |             |
|  +------------------------------------------+  |             |
|  |              refresh_ctrl                |--+             |
|  +------------------------------------------+  |             |
|                                                |             |
|  +------------------------------------------+  |             |
|  |              timing_ctrl                 |<-+             |
|  +------------------------------------------+  |             |
|                                                |             |
|  +------------------------------------------+  |             |
|  |              bank_fsm  (x16 instances)   |<-+             |
|  +------------------------------------------+                |
|                                                              |
|  +----------------+   +-----------------------------------+  |
|  |  ecc_encoder   |   |          phy_if                   |  |
|  |  ecc_decoder   |   |  (DDR4 PHY / pad interface)       |  |
|  +----------------+   +-----------------------------------+  |
+--------------------------------------------------------------+
```

| Module | File | Description |
|---|---|---|
| `ddr4_ctrl_top` | `rtl/ddr4_ctrl_top.v` | Top-level wrapper; ties all sub-modules together |
| `axi4_slave` | `rtl/axi4_slave.v` | AXI4 subordinate: accepts read/write transactions, issues internal requests |
| `cmd_arbiter` | `rtl/cmd_arbiter.v` | Arbitrates read and write queues; respects AXI ordering; priority configurable |
| `cmd_scheduler` | `rtl/cmd_scheduler.v` | Translates host requests to DRAM commands (ACTIVATE, READ, WRITE, PRECHARGE) |
| `refresh_ctrl` | `rtl/refresh_ctrl.v` | Issues REFab / REFpb commands; tracks tREFI countdown; manages tRFC stall |
| `timing_ctrl` | `rtl/timing_ctrl.v` | Enforces all JEDEC timing constraints between consecutive DRAM commands |
| `bank_fsm` | `rtl/bank_fsm.v` | Per-bank FSM (IDLE -> ACTIVATING -> ACTIVE -> PRECHARGING); tracks open row |
| `ecc_encoder` | `rtl/ecc_encoder.v` | Generates 8-bit SECDED check bits for a 64-bit data word |
| `ecc_decoder` | `rtl/ecc_decoder.v` | Corrects single-bit errors, detects double-bit errors; reports ECC status |
| `phy_if` | `rtl/phy_if.v` | DDR4 PHY interface: DQ/DQS bidir drive, write-leveling, read DQS alignment |

---

## 3. Interfaces

### 3.1 Top-level Port List (`ddr4_ctrl_top`)

#### Clock and Reset

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock (half the DRAM data-rate clock; e.g. 800 MHz for DDR4-3200) |
| `rst_n` | in | 1 | Active-low synchronous reset |

#### AXI4 Host Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axi_awid` | in | AXI_ID_W | Write address ID |
| `s_axi_awaddr` | in | AXI_ADDR_W | Write address (byte-addressed) |
| `s_axi_awlen` | in | 8 | Burst length minus 1 (AXI4) |
| `s_axi_awsize` | in | 3 | Transfer size |
| `s_axi_awburst` | in | 2 | Burst type (INCR expected) |
| `s_axi_awvalid` | in | 1 | Write address valid |
| `s_axi_awready` | out | 1 | Write address ready |
| `s_axi_wdata` | in | AXI_DATA_W | Write data |
| `s_axi_wstrb` | in | AXI_DATA_W/8 | Write strobes |
| `s_axi_wlast` | in | 1 | Last beat of write burst |
| `s_axi_wvalid` | in | 1 | Write data valid |
| `s_axi_wready` | out | 1 | Write data ready |
| `s_axi_bid` | out | AXI_ID_W | Write response ID |
| `s_axi_bresp` | out | 2 | Write response (OKAY / SLVERR for uncorrectable ECC) |
| `s_axi_bvalid` | out | 1 | Write response valid |
| `s_axi_bready` | in | 1 | Write response ready |
| `s_axi_arid` | in | AXI_ID_W | Read address ID |
| `s_axi_araddr` | in | AXI_ADDR_W | Read address |
| `s_axi_arlen` | in | 8 | Burst length minus 1 |
| `s_axi_arsize` | in | 3 | Transfer size |
| `s_axi_arburst` | in | 2 | Burst type |
| `s_axi_arvalid` | in | 1 | Read address valid |
| `s_axi_arready` | out | 1 | Read address ready |
| `s_axi_rid` | out | AXI_ID_W | Read data ID |
| `s_axi_rdata` | out | AXI_DATA_W | Read data |
| `s_axi_rresp` | out | 2 | Read response (SLVERR on double-bit ECC error) |
| `s_axi_rlast` | out | 1 | Last beat of read burst |
| `s_axi_rvalid` | out | 1 | Read data valid |
| `s_axi_rready` | in | 1 | Read data ready |

#### ECC Status

| Port | Dir | Width | Description |
|---|---|---|---|
| `ecc_single_err` | out | 1 | Pulse: single-bit ECC error corrected |
| `ecc_double_err` | out | 1 | Pulse: uncorrectable double-bit ECC error detected |
| `ecc_err_addr` | out | AXI_ADDR_W | Address of last ECC error |

#### DDR4 DRAM Interface (to PHY / pads)

| Port | Dir | Width | Description |
|---|---|---|---|
| `ddr4_ck_p/n` | out | RANKS | Differential clock to DRAM |
| `ddr4_cke` | out | RANKS | Clock enable |
| `ddr4_cs_n` | out | RANKS | Chip select (active-low) |
| `ddr4_act_n` | out | 1 | Activate command indicator |
| `ddr4_ras_n` | out | 1 | Row address strobe (also A16) |
| `ddr4_cas_n` | out | 1 | Column address strobe (also A15) |
| `ddr4_we_n` | out | 1 | Write enable (also A14) |
| `ddr4_ba` | out | 2 | Bank address |
| `ddr4_bg` | out | 2 | Bank group address |
| `ddr4_addr` | out | 17 | Row / column multiplexed address |
| `ddr4_odt` | out | RANKS | On-die termination control |
| `ddr4_reset_n` | out | 1 | DRAM reset (active-low) |
| `ddr4_dq` | inout | 64 | Data bus |
| `ddr4_dqs_p/n` | inout | 8 | Differential data strobes |
| `ddr4_dm_dbi_n` | inout | 8 | Data mask / data bus inversion |

#### Top-level Parameters

| Parameter | Default | Description |
|---|---|---|
| `AXI_ADDR_W` | 34 | AXI address width (supports up to 16 GB) |
| `AXI_DATA_W` | 64 | AXI data width (must match DRAM burst width) |
| `AXI_ID_W` | 8 | AXI transaction ID width |
| `RANKS` | 1 | Number of DRAM ranks |
| `BANK_GROUPS` | 4 | Bank groups per rank (DDR4: 2 or 4) |
| `BANKS_PER_GROUP` | 4 | Banks per group (DDR4: 4) |
| `ROW_ADDR_W` | 17 | Row address width |
| `COL_ADDR_W` | 10 | Column address width |
| `TCK_PS` | 625 | Clock period in picoseconds (625 ps = DDR4-3200) |

---

### 3.2 Internal Interface: `cmd_scheduler` -> `bank_fsm`

| Signal | Dir | Width | Description |
|---|---|---|---|
| `sched_cmd` | out | 3 | Command: ACT, RD, WR, PRE, REF, NOP |
| `sched_bank_group` | out | 2 | Target bank group |
| `sched_bank` | out | 2 | Target bank |
| `sched_row_addr` | out | ROW_ADDR_W | Row address for ACT |
| `sched_col_addr` | out | COL_ADDR_W | Column address for RD/WR |
| `sched_valid` | out | 1 | Command valid |
| `sched_ready` | in | 1 | Bank FSM ready to accept |

---

### 3.3 Internal Interface: `cmd_scheduler` -> `timing_ctrl`

| Signal | Dir | Width | Description |
|---|---|---|---|
| `tc_cmd` | out | 3 | Issued command type |
| `tc_bank_group` | out | 2 | Bank group of issued command |
| `tc_bank` | out | 2 | Bank of issued command |
| `tc_ok` | in | 1 | All timing constraints satisfied for proposed command |

---

### 3.4 Internal Interface: `ecc_encoder`

| Port | Dir | Width | Description |
|---|---|---|---|
| `enc_data_in` | in | 64 | Raw 64-bit write data |
| `enc_check_out` | out | 8 | 8 SECDED check bits |
| `enc_word_out` | out | 72 | {check_bits, data} written to DRAM |

---

### 3.5 Internal Interface: `ecc_decoder`

| Port | Dir | Width | Description |
|---|---|---|---|
| `dec_word_in` | in | 72 | 72-bit word read from DRAM |
| `dec_data_out` | out | 64 | Corrected 64-bit data |
| `dec_single_err` | out | 1 | Single-bit error detected and corrected |
| `dec_double_err` | out | 1 | Double-bit error detected (uncorrectable) |
| `dec_syndrome` | out | 8 | Raw syndrome for diagnostic use |

---

## 4. Timing Parameters and Protocols

### 4.1 Configurable JEDEC Timing Parameters

All timing values are **expressed in clock cycles** derived from `TCK_PS`.
The `timing_ctrl` module accepts these as parameters and enforces minimum
cycle counts between commands.

| Parameter | Symbol | DDR4-2400 (ns) | DDR4-3200 (ns) | Description |
|---|---|---|---|---|
| `tRCD` | P_TRCD | 13.5 | 13.75 | RAS-to-CAS delay (ACTIVATE to READ/WRITE) |
| `tRP` | P_TRP | 13.5 | 13.75 | Row precharge time |
| `tRAS` | P_TRAS | 32 | 32 | Minimum active time |
| `tRC` | P_TRC | 45.5 | 45.75 | Row cycle time (tRAS + tRP) |
| `tCL` | P_TCL | 16 (cycles) | 22 (cycles) | CAS latency |
| `tCWL` | P_TCWL | 12 (cycles) | 16 (cycles) | CAS write latency |
| `tRTP` | P_TRTP | 7.5 | 7.5 | Read-to-precharge time |
| `tWR` | P_TWR | 15 | 15 | Write recovery time |
| `tWTR_S` | P_TWTR_S | 2.5 | 2.5 | Write-to-read (different bank group) |
| `tWTR_L` | P_TWTR_L | 7.5 | 7.5 | Write-to-read (same bank group) |
| `tRRD_S` | P_TRRD_S | 3.3 | 2.5 | ACT-to-ACT (different bank group) |
| `tRRD_L` | P_TRRD_L | 4.9 | 4.9 | ACT-to-ACT (same bank group) |
| `tCCD_S` | P_TCCD_S | 4 (cycles) | 4 (cycles) | CAS-to-CAS (different bank group) |
| `tCCD_L` | P_TCCD_L | 5 (cycles) | 6 (cycles) | CAS-to-CAS (same bank group) |
| `tFAW` | P_TFAW | 25 | 25 | Four-activate window |
| `tXP` | P_TXP | 6 | 6 | Exit power-down to any command |
| `tREFI` | P_TREFI | 7800 | 7800 | Average refresh interval (ns) |
| `tRFC1` | P_TRFC1 | 260-550 | 260-550 | Refresh cycle time (8 Gb device, varies by density) |
| `tRFC2` | P_TRFC2 | 160-350 | 160-350 | Fine-granularity refresh cycle time |

The conversion from nanoseconds to cycles uses:
```
cycles = ceil(time_ns / (TCK_PS / 1000.0))
```

### 4.2 Refresh Policy

The `refresh_ctrl` module implements two refresh modes:

1. **All-Bank Refresh (REFab)** - the default mode.  One REF command is issued
   to all banks every tREFI (7.8 us at normal temperature).  All banks are
   stalled for tRFC after each refresh.

2. **Per-Bank Refresh (REFpb)** - optional fine-granularity mode (DDR4 JEDEC
   extension).  Refreshes one bank at a time; allows other banks to remain
   active.  The controller tracks a per-bank refresh credit counter.

Refresh has the **highest priority** in the arbiter.  When a refresh is
pending, the arbiter stops issuing new ACT commands and allows in-progress
bursts to complete, then issues the REF command.

### 4.3 ECC Scheme

The design uses a standard **SECDED (72,64) Hamming code**:

- 8 check bits cover 64 data bits.
- Any **single-bit error** is corrected transparently; `ecc_single_err` is
  pulsed for logging.
- Any **double-bit error** is detected but not corrected; `ecc_double_err` is
  pulsed and `s_axi_rresp` / `s_axi_bresp` is set to SLVERR.
- Check-bit generation and syndrome calculation follow the standard Hamming
  parity-check matrix over GF(2).

### 4.4 Write Path

```
AXI WDATA (64 b)
      |
      v
  ecc_encoder  ->  72-bit codeword
      |
      v
  write buffer (4-entry FIFO per bank group)
      |
      v
  cmd_scheduler issues WR command after tRCD from ACT
      |
      v
  phy_if drives DQ/DQS with write-leveling calibrated delay
```

### 4.5 Read Path

```
  phy_if captures DQ/DQS with read DQS alignment
      |
      v
  72-bit codeword
      |
      v
  ecc_decoder  ->  64-bit corrected data + error flags
      |
      v
  read data buffer
      |
      v
  AXI RDATA (64 b) + RRESP
```

---

## 5. Block Diagram

```
                           +---------------------------------------------+
  AXI4 Master              |           ddr4_ctrl_top                     |
  (CPU / DMA / NoC)        |                                             |
    ---------------------->|  +-------------+    +-------------------+  |
    s_axi_aw / w / b       |  | axi4_slave  |--->|   cmd_arbiter     |  |
    s_axi_ar / r           |  |             |<---|  (RD/WR priority) |  |
    <----------------------|  +-------------+    +--------+----------+  |
                           |                              |              |
                           |  +---------------------------+              |
                           |  |  +----------------------------------+    |
                           |  |  |  refresh_ctrl                    |    |
                           |  |  |  (REFab/REFpb, tREFI countdown)  |    |
                           |  |  +---------------+------------------+    |
                           |  |                  |                        |
                           |  v                  v                        |
                           |  +--------------------------------------+    |
                           |  |  cmd_scheduler                       |    |
                           |  |  (ACT/RD/WR/PRE sequencing,         |    |
                           |  |   open-row policy, FAW tracking)     |    |
                           |  +----------+----------------+----------+    |
                           |             |                |                |
                           |  +----------v---------+  +---v-------------+  |
                           |  |  timing_ctrl       |  |  bank_fsm x16   |  |
                           |  |  (tRCD,tRP,tRAS,   |  |  (IDLE/ACT/PRE) |  |
                           |  |   tRFC,tFAW, ...)  |  +--------+--------+  |
                           |  +--------------------+           |            |
                           |                                  |            |
                           |  +----------------+  +-----------v-----------+ |
                           |  | ecc_encoder    |  |       phy_if          | |
                           |  | ecc_decoder    |  |  (DQ/DQS, WL, RL)    | |
                           |  +----------------+  +-----------+-----------+ |
                           +----------------------------------------------|--+
                                                             |
                                              DDR4 DRAM (x72 DQ, DQS, CMD, ADDR)
```

---

## 6. FSM Descriptions

### 6.1 `bank_fsm` - Per-Bank State Machine

```
         rst_n = 0
              |
              v
         +---------+
         |  IDLE   |<----------------------------------+
         +----+----+                                   |
              | ACT command issued                      |
              v                                         |
         +--------------+   tRAS satisfied &            |
         |  ACTIVATING  |   row open                    |
         +------+-------+                               |
                | tRCD elapsed                          |
                v                                       |
         +------------+   RD or WR commands issued      |
         |   ACTIVE   |-------------------------+       |
         +------+-----+                         |       |
                | PRE command (or tRAS timeout) |       |
                v                               |       |
         +-----------------+                   |       |
         |  PRECHARGING    |<------------------+       |
         +--------+--------+  (auto-precharge or        |
                  |            explicit PRE)             |
                  | tRP elapsed                          |
                  +------------------------------------------+
```

States:
- **IDLE** - bank is precharged; ready for an ACTIVATE command.
- **ACTIVATING** - ACTIVATE issued; waiting tRCD before accepting RD/WR.
- **ACTIVE** - row open; RD and WR commands may be issued to this bank.
- **PRECHARGING** - PRECHARGE issued; waiting tRP before returning to IDLE.

The FSM also tracks:
- `open_row[ROW_ADDR_W-1:0]` - currently open row address.
- `tRAS_timer` - ensures minimum active time before PRECHARGE.

### 6.2 `refresh_ctrl` - Refresh State Machine

```
    +--------------+   tREFI expired   +------------------+
    |   NORMAL     |------------------>|  REF_PENDING     |
    +--------------+                   +--------+---------+
           ^                                    |  all banks idle
           |                                    v
           |                           +------------------+
           |         tRFC elapsed      |   REFRESHING     |
           +---------------------------|  (REF command     |
                                       |   to DRAM)        |
                                       +------------------+
```

---

## 7. Address Mapping

The controller maps a **linear byte address** from the AXI bus to a DRAM
address tuple (rank, bank_group, bank, row, column) using the following
default scheme (all widths configurable):

```
AXI Address [33:0]:
  [33]        -> rank select          (1 bit  if RANKS=2, else tied 0)
  [32:22]     -> row address          (11 bits, up to ROW_ADDR_W)
  [21:18]     -> bank group + bank    (4 bits: bg[1:0], ba[1:0])
  [17:8]      -> column address high  (10 bits)
  [7:3]       -> column address low / burst offset (5 bits, BL8 = 3 bits used)
  [2:0]       -> byte offset within 8-byte word
```

The mapping is designed to distribute consecutive cache-line accesses across
different bank groups, exploiting DDR4 bank-group parallelism (tCCD_S < tCCD_L).

---

## 8. Notes and Assumptions

1. **PHY not included** - `phy_if` is modelled as an RTL wrapper with DQ/DQS
   bidir logic; actual DLL/PLL calibration is vendor-specific and out of scope.
2. **Single channel** - multi-channel operation requires instantiating multiple
   `ddr4_ctrl_top` modules.
3. **Power-down modes** - self-refresh (SREF) and power-down (PD) entries are
   tracked by `refresh_ctrl` but not driven autonomously; a sideband
   `pwr_down_req` input can trigger them.
4. **Write leveling / read DQS alignment** - firmware-assisted calibration at
   startup; the controller exposes calibration mode pins.
5. **Temperature-compensated refresh** - the design supports a
   `temp_throttle` input that halves tREFI at high temperature (>85 C)
   per JEDEC DDR4 DRAM specification.
6. **JEDEC references**:
   - JEDEC JESD79-4B - DDR4 SDRAM Standard
   - JEDEC JESD79-4C - DDR4 SDRAM Addendum (fine-granularity refresh)
   - JEDEC JESD21C - SPD and module standards

---

## 9. Implementation Plan Reference

See [docs/PLAN.md](PLAN.md) for the phased implementation checklist.

All RTL files live in `rtl/`, testbenches in `tb/`, per-module docs in
`docs/<module>.md`, and simulation artifacts under `results/phase-ddr4/`.
