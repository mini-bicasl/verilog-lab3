# bank_fsm – Per-Bank State Machine

## Overview

`bank_fsm` implements the per-bank state machine for the DDR4 controller
described in `docs/ARCHITECTURE.md §6.1`.  One instance is required for
each bank in the design (16 instances for the default 4 bank-groups × 4
banks-per-group configuration).

The module tracks whether a bank is idle (precharged), activating, active
(row open), or precharging, and enforces the JEDEC DDR4 timing constraints
tRCD, tRAS, and tRP.  It is driven by `cmd_scheduler` and exposes a
handshake interface so the scheduler knows when a new command can be accepted.

## Source Files

| Role | Path |
|---|---|
| RTL | `rtl/bank_fsm.v` |
| Testbench | `tb/bank_fsm_tb.v` |

---

## Interface

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `ROW_ADDR_W` | 17 | Row address width (bits) |
| `P_TRCD` | 14 | tRCD: ACT-to-RD/WR delay (clock cycles, ≥ 2) |
| `P_TRAS` | 52 | tRAS: minimum active time from ACT (clock cycles) |
| `P_TRP` | 14 | tRP: precharge recovery time (clock cycles, ≥ 2) |

All timing values are in **clock cycles** as derived from `TCK_PS` and the
standard JEDEC conversion `cycles = ceil(time_ns / (TCK_PS / 1000.0))`.

### Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock (active rising edge) |
| `rst_n` | in | 1 | Active-low asynchronous reset; drives FSM to IDLE |
| `cmd_in` | in | 3 | Command: `CMD_NOP`/`CMD_ACT`/`CMD_RD`/`CMD_WR`/`CMD_PRE`/`CMD_REF` |
| `row_addr_in` | in | ROW_ADDR_W | Row address carried with `CMD_ACT` |
| `cmd_valid` | in | 1 | Qualifies `cmd_in` this cycle |
| `fsm_ready` | out | 1 | 1 when the FSM can accept a command |
| `open_row` | out | ROW_ADDR_W | Currently open row address (valid while in ACTIVE) |
| `row_active` | out | 1 | 1 when in ACTIVE state; row is open |
| `tras_ok` | out | 1 | 1 when tRAS constraint satisfied (PRE may be issued) |
| `state_out` | out | 2 | Raw FSM state for debug/visibility |

### Command Encodings

| Mnemonic | `cmd_in` | Accepted in State | Effect |
|---|---|---|---|
| `CMD_NOP` | `3'd0` | Any | No operation |
| `CMD_ACT` | `3'd1` | IDLE | Opens a row; starts tRCD and tRAS timers |
| `CMD_RD` | `3'd2` | ACTIVE | Read burst; no state change |
| `CMD_WR` | `3'd3` | ACTIVE | Write burst; no state change |
| `CMD_PRE` | `3'd4` | ACTIVE (only when `tras_ok=1`) | Closes row; starts tRP timer |
| `CMD_REF` | `3'd5` | (managed externally) | Ignored by this FSM |

---

## FSM Description

```
          rst_n = 0
               |
               v
          +---------+
          |  IDLE   |<------------------------------------------+
          +----+----+                                            |
               | cmd_valid && cmd_in == CMD_ACT                  |
               v                                                 |
          +--------------+                                       |
          |  ACTIVATING  |  tRCD and tRAS timers both running    |
          +------+-------+                                       |
                 | tRCD elapsed (P_TRCD cycles from ACT)        |
                 v                                               |
          +------------+                                         |
          |   ACTIVE   |  row open; RD/WR accepted;             |
          +------+-----+  tRAS timer still running              |
                 | cmd_valid && cmd_in == CMD_PRE && tras_ok     |
                 v                                               |
          +-----------------+                                    |
          |  PRECHARGING    |  tRP timer running                 |
          +--------+--------+                                    |
                   | tRP elapsed (P_TRP cycles from PRE)        |
                   +--------------------------------------------+
```

### Timing Counters

| Counter | Loaded At | Initial Value | Purpose |
|---|---|---|---|
| `trcd_cnt` | ACT accepted in IDLE | `P_TRCD - 2` | Counts down; ACTIVATING→ACTIVE when 0 |
| `tras_cnt` | ACT accepted in IDLE | `P_TRAS - 1` | Counts down through ACTIVATING+ACTIVE; `tras_ok` when 0 |
| `trp_cnt` | PRE accepted in ACTIVE | `P_TRP - 2` | Counts down; PRECHARGING→IDLE when 0 |

The counter initialisation ensures that the actual dwell time equals the
configured parameter value:

- **tRCD**: the FSM stays in ACTIVATING for exactly `P_TRCD` clock cycles
  (from the ACT edge to the first clock edge in which `fsm_ready` is 1 in
  ACTIVE state).
- **tRAS**: `tras_ok` asserts exactly `P_TRAS` clock cycles after the ACT
  command.  A PRE received before `tras_ok` is silently discarded; the FSM
  remains in ACTIVE.
- **tRP**: the FSM stays in PRECHARGING for exactly `P_TRP` clock cycles
  (from the PRE edge to the first clock edge in which `fsm_ready` is 1 in
  IDLE state).

### Reset Behaviour

On `rst_n = 0` the FSM **asynchronously** enters IDLE with all counters zeroed
and `open_row` cleared.  `fsm_ready` asserts immediately.

---

## Integration Notes

- Instantiated × 16 inside `ddr4_ctrl_top` (4 bank groups × 4 banks).
- `cmd_scheduler` drives `cmd_in`, `row_addr_in`, and `cmd_valid` after
  consulting `timing_ctrl` to ensure JEDEC timing between commands.
- `open_row` is used by `cmd_scheduler` to detect row hits (avoiding a
  redundant ACT).
- `tras_ok` must be checked by the scheduler before issuing `CMD_PRE`.
  Issuing PRE while `tras_ok = 0` has no effect (the command is ignored).

---

## Verification Coverage

| Scenario | Covered by |
|---|---|
| Reset → IDLE | T1 |
| ACT → ACTIVATING (row latched) | T2 |
| ACTIVATING dwell = P_TRCD cycles | T3 |
| ACTIVE state; RD/WR no state change | T4 |
| PRE blocked before `tras_ok` | T5 |
| `tras_ok` asserts after P_TRAS cycles | T6 |
| PRE → PRECHARGING | T6 |
| PRECHARGING dwell = P_TRP cycles | T7 |
| PRECHARGING → IDLE | T8 |
| Full second cycle end-to-end | T9 |
| `open_row` stable across RD bursts | T10 |
