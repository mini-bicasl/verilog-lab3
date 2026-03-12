# cmd_scheduler

## Overview

`cmd_scheduler` translates arbitrated host requests (from `cmd_arbiter`) into
the correct DDR4 DRAM command sequences: ACTIVATE, READ/WRITE, and PRECHARGE.
It enforces the **open-row policy** and defers to `timing_ctrl` for all
JEDEC timing constraints.

System position (from [docs/ARCHITECTURE.md](ARCHITECTURE.md) §2):

```
cmd_arbiter → cmd_scheduler → timing_ctrl
                           └─→ bank_fsm × 16  (via sched_* ports)
                           └─→ DRAM bus (dram_cmd, dram_valid, ...)
```

---

## Open-Row Policy

| Condition | Command sequence issued |
|---|---|
| **Open-row hit**: target bank is active and the requested row is already open | `RD` or `WR` only |
| **Open-row miss**: target bank is idle (precharged) | `ACT` → `RD`/`WR` |
| **Row conflict**: target bank is active with a *different* row open | `PRE` → `ACT` → `RD`/`WR` |

The open-row table (16 entries, one per `{bank_group[1:0], bank[1:0]}` slot)
is maintained internally by `cmd_scheduler`.  It is updated when ACT or PRE
commands issue and is fully cleared when a refresh pulse (`ref_issue`) is
received.

---

## Interface

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `AXI_ADDR_W` | 34 | AXI address width |
| `AXI_ID_W` | 8 | AXI transaction ID width |
| `BANK_GROUPS` | 4 | Bank groups per rank (informs address decode context) |
| `BANKS_PER_GROUP` | 4 | Banks per group |
| `ROW_ADDR_W` | 17 | Row address width |
| `COL_ADDR_W` | 10 | Column address width |

### Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low asynchronous reset |
| `arb_valid` | in | 1 | Request valid from cmd_arbiter |
| `arb_ready` | out | 1 | Scheduler ready to accept (deasserted when busy or refresh pending) |
| `arb_is_write` | in | 1 | `1` = write, `0` = read |
| `arb_addr` | in | AXI_ADDR_W | Request address |
| `ref_req` | in | 1 | Refresh pending – deasserts `arb_ready` |
| `ref_issue` | in | 1 | 1-cycle pulse: issue REF now and clear row state |
| `tc_cmd` | out | 3 | Proposed command to `timing_ctrl` |
| `tc_bank_group` | out | 2 | Bank group of proposed command |
| `tc_bank` | out | 2 | Bank of proposed command |
| `tc_ok` | in | 1 | `1` = all timing constraints satisfied; command may issue |
| `dram_cmd` | out | 3 | Issued DRAM command (`= tc_cmd` when `dram_valid`) |
| `dram_bank_group` | out | 2 | Target bank group |
| `dram_bank` | out | 2 | Target bank |
| `dram_row_addr` | out | ROW_ADDR_W | Row address (valid when `dram_cmd = ACT`) |
| `dram_col_addr` | out | COL_ADDR_W | Column address (valid when `dram_cmd = RD/WR`) |
| `dram_valid` | out | 1 | `1` when a command is issued this cycle |

---

## FSM Description

```
         rst_n = 0
              |
              v
         +--------+
    +--->|  IDLE  |<---+
    |    +---+----+    |
    |        |         | tc_ok (S_DATA)
    |        | arb_valid && !ref_req
    |        v
    |    +--------+
    |    | S_PRE  | (only if row conflict)
    |    +---+----+
    |        | tc_ok
    |        v
    |    +--------+
    |    | S_ACT  |
    |    +---+----+
    |        | tc_ok
    |        v
    |    +--------+
    +----| S_DATA |
         +--------+
```

State summary:

| State | `tc_cmd` proposed | Transition |
|---|---|---|
| `S_IDLE` | `NOP` (or `REF` if `ref_issue`) | → `S_PRE`/`S_ACT`/`S_DATA` on `arb_valid` |
| `S_PRE` | `CMD_PRE` | → `S_ACT` when `tc_ok = 1` |
| `S_ACT` | `CMD_ACT` | → `S_DATA` when `tc_ok = 1` |
| `S_DATA` | `CMD_RD` or `CMD_WR` | → `S_IDLE` when `tc_ok = 1` |

A command is issued (`dram_valid = 1`) only when `tc_ok = 1`.  The
scheduler holds `tc_cmd` stable across multiple cycles while waiting for
`tc_ok`; `timing_ctrl` reloads its counters on the following posedge.

### Refresh Handling

When `ref_issue` is asserted (1-cycle pulse from `refresh_ctrl`) while in
`S_IDLE`, the scheduler immediately issues `CMD_REF` on the DRAM bus
(`tc_ok` is always `1` for REF per `timing_ctrl` specification) and clears
the entire open-row table.  `arb_ready` remains deasserted whenever
`ref_req` or `ref_issue` is active.

---

## Address Decode

Fixed bit positions per [docs/ARCHITECTURE.md §7](ARCHITECTURE.md):

```
arb_addr[32:22] → row address (11 bits, zero-padded to ROW_ADDR_W)
arb_addr[21:20] → bank group  (2 bits)
arb_addr[19:18] → bank        (2 bits)
arb_addr[17:8]  → column      (COL_ADDR_W bits)
```

The flat bank index is `{bank_group[1:0], bank[1:0]}` – a 4-bit value
in `[0:15]`, matching the encoding used by `timing_ctrl`.

---

## Command Encodings

| Constant | Value | Meaning |
|---|---|---|
| `CMD_NOP` | 3'd0 | No operation |
| `CMD_ACT` | 3'd1 | Activate row |
| `CMD_RD`  | 3'd2 | Read |
| `CMD_WR`  | 3'd3 | Write |
| `CMD_PRE` | 3'd4 | Precharge |
| `CMD_REF` | 3'd5 | Refresh |

---

## Reset Behavior

All outputs are de-asserted and the internal open-row table is cleared on
active-low asynchronous reset (`negedge rst_n`).

---

## Files

| Role | Path |
|---|---|
| RTL | `rtl/cmd_scheduler.v` |
| Testbench | `tb/cmd_scheduler_tb.v` |
| Results | `results/phase-ddr4-sched/` |
