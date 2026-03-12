# ddr4_ctrl_top – DDR4 Controller Top-Level Integration

## Overview

`ddr4_ctrl_top` is the top-level integration module for the DDR4 memory controller.  It instantiates and wires together all sub-modules to form a complete AXI4-to-DDR4 pipeline.

```
Host AXI4 Master
      │
 ┌────▼────────┐
 │ axi4_slave  │  AXI4 subordinate interface
 └──┬────────┬─┘
    │wr       │rd
 ┌──▼─────────▼──┐
 │  cmd_arbiter  │  Priority arbiter (reads preferred)
 └──────┬────────┘
        │ arb_valid/ready
 ┌──────▼────────┐      ┌───────────────┐
 │ cmd_scheduler │◄─────│ refresh_ctrl  │ ref_req / ref_issue
 └──┬─────────┬──┘      └───────────────┘
    │ tc_cmd  │ dram_cmd/valid
    │         │
 ┌──▼──────┐  │  ┌──────────────────────────┐
 │timing_  │  └─►│ bank_fsm × 16            │ all_banks_idle
 │ctrl     │     │ (one per {bg,bank})       │──────────────►
 └────┬────┘     └──────────────────────────┘
      │ tc_ok
      │
 ┌────▼──────────────────────────────────────────┐
 │              phy_if                           │  DDR4 pads
 │  write: wr_dq(64-bit) + wr_dm(8 ECC check)   │───────────►
 │  read:  rd_dq(64-bit) + rd_dm(8 ECC bits)    │◄───────────
 └────┬──────────────────┬───────────────────────┘
      │ write path        │ read path
 ┌────▼────┐        ┌────▼────┐
 │ecc_encod│        │ecc_decod│
 └─────────┘        └────┬────┘
                         │ dec_data_out / dec_single_err / dec_double_err
                    Back to axi4_slave (rd_data / rd_ecc_*)
```

## Interface

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `AXI_ADDR_W` | 34 | AXI4 address width (bits) |
| `AXI_DATA_W` | 64 | AXI4 data width (bits) |
| `AXI_ID_W`   | 8  | AXI4 ID width (bits) |
| `RANKS`      | 1  | DRAM rank count |
| `BANK_GROUPS` | 4 | DDR4 bank groups |
| `BANKS_PER_GROUP` | 4 | Banks per group |
| `ROW_ADDR_W` | 17 | Row address width |
| `COL_ADDR_W` | 10 | Column address width |
| `P_TRCD` | 14 | ACT→RD/WR cycles |
| `P_TRP`  | 14 | PRE→ACT cycles |
| `P_TRAS` | 52 | ACT→PRE minimum cycles |
| `P_TRC`  | 66 | ACT→ACT same bank cycles |
| `P_TRRD_S` | 4 | ACT→ACT different bank group |
| `P_TRRD_L` | 6 | ACT→ACT same bank group |
| `P_TCCD_S` | 4 | CAS→CAS different bank group |
| `P_TCCD_L` | 6 | CAS→CAS same bank group |
| `P_TFAW` | 40 | Four-activate window |
| `P_TWTR_S` | 4 | WR→RD different bank group |
| `P_TWTR_L` | 12 | WR→RD same bank group |
| `P_TRTP` | 12 | RD→PRE |
| `P_TWR`  | 24 | WR→PRE (write recovery) |
| `P_TCL`  | 11 | CAS latency |
| `P_TCWL` | 9  | CAS write latency |
| `P_TBURST` | 4 | Write burst duration (BL8/2) |
| `P_TREFI` | 12480 | tREFI cycles |
| `P_TRFC`  | 560  | tRFC cycles |

### Ports

#### Clock / Reset

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk`   | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low async reset |

#### AXI4 Host Interface

Standard AXI4 write/read address, write data, write response, and read data channels.  `AXI_ID_W`-bit IDs are forwarded end-to-end.

#### ECC Status Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `ecc_single_err` | out | 1 | Single-bit error corrected (pulsed with read data) |
| `ecc_double_err` | out | 1 | Double-bit error detected (read → SLVERR) |
| `ecc_err_addr`   | out | AXI_ADDR_W | Address of last ECC error |

#### DDR4 DRAM Pads

All standard DDR4 pad signals: `ddr4_ck_p/n`, `ddr4_cke`, `ddr4_cs_n`, `ddr4_act_n`, `ddr4_ras_n`, `ddr4_cas_n`, `ddr4_we_n`, `ddr4_ba[1:0]`, `ddr4_bg[1:0]`, `ddr4_addr[ROW_ADDR_W-1:0]`, `ddr4_odt`, `ddr4_reset_n`, plus bidir `ddr4_dq[63:0]`, `ddr4_dqs_p/n[7:0]`, `ddr4_dm_dbi_n[7:0]`.

## Data Flow

### Write Path

1. AXI master drives `s_axi_aw*` and `s_axi_w*`.
2. `axi4_slave` issues a write address request (`wr_valid`) to `cmd_arbiter`.
3. `cmd_arbiter` forwards the request to `cmd_scheduler` (`arb_valid/ready`).
4. `cmd_scheduler` sequences PRECHARGE→ACTIVATE→WRITE commands, gated by `timing_ctrl`.
5. `phy_if` receives the WR command, counts P_TCWL, then drives `ddr4_dq` with the 64-bit write data and `ddr4_dm_dbi_n` with the 8-bit ECC check bits from `ecc_encoder`.
6. `axi4_slave` sends a OKAY B-channel response.

### Read Path

1. AXI master drives `s_axi_ar*`.
2. `axi4_slave` issues a read address request (`rd_valid`) to `cmd_arbiter`.
3. `cmd_arbiter` → `cmd_scheduler` sequences PRE/ACT/READ.
4. `phy_if` issues the READ command, then counts P_TCL clocks and captures `ddr4_dq` / `ddr4_dm_dbi_n` from the DRAM.
5. `ecc_decoder` checks the 72-bit codeword for errors.  Single-bit errors are corrected; double-bit errors set `ecc_double_err`.
6. `axi4_slave` sends the corrected data on the R channel.  If `ecc_double_err`, `rresp = SLVERR`.

### Refresh

`refresh_ctrl` counts `P_TREFI` clock cycles.  When expired it asserts `ref_req` to halt new commands.  Once `all_banks_idle` (all 16 bank FSMs in IDLE/precharged state), `ref_issue` fires for one cycle, which `cmd_scheduler` passes to the `phy_if` as a REF command.  After `P_TRFC` cycles `refresh_ctrl` resumes normal operation.

## Address Decode

Per `docs/ARCHITECTURE.md §7` (and `cmd_scheduler.v`):

| AXI bits | DRAM field |
|----------|------------|
| `[32:22]` | Row address (11 bits, zero-padded to ROW_ADDR_W) |
| `[21:20]` | Bank group |
| `[19:18]` | Bank |
| `[17:8]`  | Column address (10 bits) |
| `[7:0]`   | Byte offset (not decoded) |

## ECC Scheme

SECDED (72,64) Hamming code.  Eight check bits (cb[7:0]) are generated by `ecc_encoder` and stored in `ddr4_dm_dbi_n`.  `ecc_decoder` recomputes the syndrome on read.

- `syndrome[7] = 1` → single-bit error: corrected transparently; `ecc_single_err` pulsed.
- `syndrome[7] = 0, syndrome[6:0] ≠ 0` → double-bit error: data not correctable; `ecc_double_err` pulsed, AXI R response uses `rresp = SLVERR`.

## Sub-module Instances

| Instance | Module | Role |
|----------|--------|------|
| `u_axi4_slave`   | `axi4_slave`   | AXI4 subordinate |
| `u_cmd_arbiter`  | `cmd_arbiter`  | Read/write priority arbiter |
| `u_cmd_scheduler`| `cmd_scheduler`| DRAM command sequencer |
| `u_refresh_ctrl` | `refresh_ctrl` | tREFI/tRFC controller |
| `u_timing_ctrl`  | `timing_ctrl`  | JEDEC timing constraint enforcer |
| `gen_bank_fsm[0..15]` | `bank_fsm` | 16× per-bank FSMs |
| `u_ecc_encoder`  | `ecc_encoder`  | SECDED check-bit generator |
| `u_ecc_decoder`  | `ecc_decoder`  | SECDED error corrector |
| `u_phy_if`       | `phy_if`       | DDR4 PHY bidir pad driver |

## Reset Behaviour

Active-low asynchronous reset (`rst_n`).  All sub-modules share the same reset.  `ddr4_reset_n = rst_n`; `ddr4_cke = rst_n` (simplified: CKE follows reset, no separate init sequence).

## Known Limitations

- **Auto-precharge not implemented**: open rows stay active until a row-conflict triggers PRECHARGE.  The `all_banks_idle` condition (used by `refresh_ctrl` before issuing REFab) is only true when every bank has been explicitly precharged via a row-conflict.  In production, the controller would issue explicit PRECHARGEs before refresh.
- Single-beat AXI bursts only (awlen=0, arlen=0).
- Single rank (`RANKS=1` default).
- No write-leveling calibration (`wl_mode` is tied to 0).

## Files

- `rtl/ddr4_ctrl_top.v`   – synthesizable RTL
- `tb/ddr4_ctrl_top_tb.v` – unit testbench (Icarus Verilog)
- `docs/ddr4_ctrl_top.md` – this document
- `results/phase-ddr4-top/` – simulation artifacts
