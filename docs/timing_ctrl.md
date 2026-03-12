# `timing_ctrl` – JEDEC DDR4 Timing Constraint Enforcer

## Overview

`timing_ctrl` is the timing-gate module of the DDR4 controller pipeline
(see `docs/ARCHITECTURE.md`, §2).  The `cmd_scheduler` proposes a command
every cycle; `timing_ctrl` checks every applicable JEDEC timing rule and
asserts `tc_ok = 1` only when all constraints are satisfied.  When `tc_ok = 1`
the command is considered issued, and the affected counters reload on the next
rising clock edge.

---

## Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low asynchronous reset |
| `tc_cmd` | in | 3 | Proposed command: NOP/ACT/RD/WR/PRE/REF |
| `tc_bank_group` | in | 2 | Bank group of proposed command |
| `tc_bank` | in | 2 | Bank of proposed command |
| `tc_ok` | out | 1 | 1 = all constraints satisfied; command may issue |

`tc_ok` is a purely combinational wire; it reflects the current counter state
with zero extra latency.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `BANK_GROUPS` | 4 | Number of bank groups |
| `BANKS_PER_GROUP` | 4 | Banks per group (total 16 banks) |
| `P_TRCD` | 14 | ACT → RD/WR (cycles) |
| `P_TRP` | 14 | PRE → ACT (cycles) |
| `P_TRAS` | 52 | ACT → earliest PRE (cycles) |
| `P_TRC` | 66 | ACT → ACT same bank (= tRAS + tRP, cycles) |
| `P_TRRD_S` | 4 | ACT → ACT, different bank group (cycles) |
| `P_TRRD_L` | 6 | ACT → ACT, same bank group (cycles) |
| `P_TCCD_S` | 4 | CAS → CAS, different bank group (cycles) |
| `P_TCCD_L` | 6 | CAS → CAS, same bank group (cycles) |
| `P_TFAW` | 40 | Four-activate window (cycles) |
| `P_TWTR_S` | 4 | WR → RD, different bank group (cycles) |
| `P_TWTR_L` | 12 | WR → RD, same bank group (cycles) |
| `P_TRTP` | 12 | RD → PRE (cycles) |
| `P_TWR` | 24 | WR → PRE – write recovery (cycles) |

All defaults match DDR4-3200 rounded up to whole clock cycles.

---

## Constraints Enforced

### Per-command gate

| Command | Constraints checked |
|---|---|
| ACT | tRRD_S (global), tRRD_L (same BG), tFAW (4-ACT window), tRP (bank), tRC (bank) |
| RD | tCCD_S (global), tCCD_L (same BG), tWTR_S (global), tWTR_L (same BG), tRCD (bank) |
| WR | tCCD_S (global), tCCD_L (same BG), tRCD (bank) |
| PRE | tRAS (bank), tRTP (bank), tWR (bank) |
| NOP / REF | Always OK (`tc_ok = 1`) |

### Counter types

| Scope | Counters |
|---|---|
| Global (1 per constraint) | `trrd_s`, `tccd_s`, `twtr_s` |
| Per bank group (4 entries) | `trrd_l`, `tccd_l`, `twtr_l` |
| Per bank (16 entries) | `trcd`, `tras`, `trp`, `trc`, `trtp`, `twr` |
| tFAW slots (4 global) | `faw_cnt[0..3]` |

All counters are 8-bit, counting down to 0 (0 = constraint satisfied).
A counter loaded with `P − 1` reaches 0 exactly `P` clock cycles after the
issuing command, implementing the JEDEC "minimum P-cycle gap" semantics.

---

## tFAW Implementation

Four independent 8-bit countdown slots track the last four ACT commands.
`tc_ok` for ACT requires **at least one slot to be zero** (i.e. fewer than
four ACTs in the current tFAW window).  When an ACT is issued, the
lowest-indexed free slot is loaded with `P_TFAW − 1`.

---

## Counter Loading (Sequential Block)

Counters are updated on `posedge clk` (or cleared asynchronously on
`negedge rst_n`).  Load takes priority over decrement:

```
counter_next = (load_condition) ? (P − 1)
             : (counter != 0)   ? counter − 1
             :                    0;
```

This means: a command issued at cycle T loads a counter that reaches 0 at
cycle T + P, allowing the next constrained command to issue at T + P.

---

## Bank Indexing

A flat 4-bit index `bidx = {tc_bank_group, tc_bank}` addresses per-bank
counters (0 = BG0/Bank0 … 15 = BG3/Bank3).

---

## Reset Behaviour

All counters reset to 0 on `negedge rst_n` (active-low asynchronous).
`tc_ok = 1` for all command types immediately after reset (all constraints
start satisfied).

---

## Files

| File | Description |
|---|---|
| `rtl/timing_ctrl.v` | Synthesizable RTL |
| `tb/timing_ctrl_tb.v` | Unit testbench (14 directed tests) |

## Simulation

```bash
iverilog -g2012 -o build/timing_ctrl.out tb/timing_ctrl_tb.v rtl/timing_ctrl.v
vvp build/timing_ctrl.out
```

Results written to `results/phase-ddr4-timing/`.
