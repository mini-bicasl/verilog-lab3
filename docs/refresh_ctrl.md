# `refresh_ctrl` – DDR4 Refresh Controller

## Overview

`refresh_ctrl` issues DDR4 **All-Bank Refresh (REFab)** and **Per-Bank Refresh
(REFpb)** commands at the JEDEC-mandated tREFI interval.  It is a sub-module
of the DDR4 controller described in [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)
(see §4.2 *Refresh Policy* and §6.2 *Refresh FSM*).

The module drives a `ref_req` flag that tells the arbiter to stop issuing new
ACTIVATE commands so that all banks drain to the idle (precharged) state.
Once `all_banks_idle` is asserted, the module pulses `ref_issue` for one cycle
and then holds `ref_stall` high for the full tRFC duration, blocking any other
commands to the DRAM.

A `temp_throttle` input halves the effective tREFI when the DRAM junction
temperature exceeds 85 °C, as required by JEDEC JESD79-4B.

---

## Files

| Type | Path |
|---|---|
| RTL | `rtl/refresh_ctrl.v` |
| Testbench | `tb/refresh_ctrl_tb.v` |

---

## Interface

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `BANK_GROUPS` | 4 | Number of bank groups per rank |
| `BANKS_PER_GROUP` | 4 | Banks per group (DDR4: 4) |
| `P_TREFI` | 12480 | tREFI in clock cycles (7800 ns ÷ 0.625 ns for DDR4-3200) |
| `P_TRFC` | 560 | tRFC in clock cycles (350 ns ÷ 0.625 ns, 8 Gb device) |

### Port List

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low synchronous reset |
| `all_banks_idle` | in | 1 | All bank FSMs are in IDLE (precharged) |
| `rfsh_mode` | in | 1 | `0` = REFab (all-bank), `1` = REFpb (per-bank) |
| `temp_throttle` | in | 1 | `1` = high temperature; halve tREFI |
| `ref_req` | out | 1 | Refresh pending; arbiter must stop new ACT commands |
| `ref_issue` | out | 1 | Single-cycle pulse: issue REF command to DRAM now |
| `ref_stall` | out | 1 | `1` during tRFC countdown; all commands blocked |
| `ref_active` | out | 1 | `1` whenever FSM is not in NORMAL state |
| `ref_bank_group` | out | 2 | Target bank group for REFpb (valid on `ref_issue`) |
| `ref_bank` | out | 2 | Target bank for REFpb (valid on `ref_issue`) |

---

## FSM Description

```
    +--------------+  tREFI expired   +------------------+
    |   NORMAL     |----------------->|  REF_PENDING     |
    +--------------+                  +--------+---------+
           ^                                   |  all_banks_idle
           |                                   v
           |                          +------------------+
           |        tRFC elapsed      |   REFRESHING     |
           +--------------------------|  (ref_issue=1,   |
                                      |   ref_stall=1)   |
                                      +------------------+
```

### State Descriptions

| State | `ref_req` | `ref_stall` | `ref_active` | Description |
|---|---|---|---|---|
| `NORMAL` | 0 | 0 | 0 | Counting down tREFI; normal operation |
| `REF_PENDING` | 1 | 0 | 1 | Waiting for all banks to precharge |
| `REFRESHING` | 0 | 1 | 1 | REF command issued; tRFC countdown active |

### tREFI Counter

The `trefi_cnt` counter is loaded with `P_TREFI − 1` at reset and reloaded
every time the FSM transitions from `NORMAL` → `REF_PENDING`.

When `temp_throttle` asserts mid-interval, the counter is clamped to
`(P_TREFI / 2) − 1` on the next clock edge so that the throttled interval
takes effect immediately without waiting for the current interval to expire.

### tRFC Counter

`trfc_cnt` is loaded with `P_TRFC − 1` on entry to `REFRESHING`.  It counts
down to zero, at which point `ref_stall` de-asserts and the FSM returns to
`NORMAL`.

### Per-Bank Refresh (REFpb)

When `rfsh_mode = 1`, the module maintains a `bank_idx` register that cycles
through `0 … (BANK_GROUPS × BANKS_PER_GROUP) − 1`.  On each `ref_issue`
pulse, `ref_bank_group = bank_idx / BANKS_PER_GROUP` and
`ref_bank = bank_idx % BANKS_PER_GROUP` identify the target bank.  `bank_idx`
advances after each tRFC completes and wraps to 0 after all banks have been
visited.

---

## Key Constraints and Assumptions

- Reset is **synchronous active-low** (`posedge clk`).
- `all_banks_idle` is assumed to be a registered signal from the bank FSMs; hold
  it high for at least one cycle after all banks reach IDLE.
- `P_TREFI` and `P_TRFC` must be ≥ 2.
- `BANKS_PER_GROUP` must be a power of two (required by DDR4 spec and assumed
  by the bank-index division logic).
- `ref_issue` is a **single-cycle pulse**; the consumer must latch it.

---

## Simulation Results

Testbench: `tb/refresh_ctrl_tb.v` with compact parameters
(`P_TREFI=20`, `P_TRFC=8`, `BANK_GROUPS=2`, `BANKS_PER_GROUP=2`).

| Test | Description | Result |
|---|---|---|
| T1 | Reset state | PASS |
| T2 | REFab – ref_req after tREFI | PASS |
| T3 | ref_issue fires when banks idle | PASS |
| T4 | ref_stall held for P_TRFC cycles | PASS |
| T5 | Return to NORMAL after tRFC | PASS |
| T6 | Second REFab cycle auto-triggered | PASS |
| T7 | temp_throttle halves tREFI | PASS |
| T8 | REFpb cycles through all 4 banks | PASS |
| T9 | ref_issue blocked while banks busy | PASS |

Artifacts: `results/phase-ddr4-refresh/`
