# cmd_arbiter

## Overview

`cmd_arbiter` arbitrates between read and write request queues produced by
the AXI4 slave interface and forwards a single selected request per
transaction to `cmd_scheduler`.  It sits in the datapath described in
[docs/ARCHITECTURE.md](ARCHITECTURE.md) §2:

```
axi4_slave → cmd_arbiter → cmd_scheduler
```

Refresh requests from `refresh_ctrl` take the highest priority: when
`ref_req` is asserted, no new commands are forwarded to the scheduler.

---

## Interface

### Parameters

| Parameter    | Default | Description |
|---|---|---|
| `AXI_ADDR_W` | 34 | AXI address width (bits) |
| `AXI_ID_W`   | 8  | AXI transaction ID width (bits) |
| `RD_PRIORITY`| 1  | Priority policy: `1` = reads preferred, `0` = writes preferred |

### Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low asynchronous reset |
| `ref_req` | in | 1 | Refresh pending – block new downstream commands |
| `rd_valid` | in | 1 | Read request valid |
| `rd_ready` | out | 1 | Read request accepted (1-cycle pulse) |
| `rd_addr` | in | AXI_ADDR_W | Read address |
| `rd_id` | in | AXI_ID_W | Read transaction ID |
| `wr_valid` | in | 1 | Write request valid |
| `wr_ready` | out | 1 | Write request accepted (1-cycle pulse) |
| `wr_addr` | in | AXI_ADDR_W | Write address |
| `wr_id` | in | AXI_ID_W | Write transaction ID |
| `arb_valid` | out | 1 | Arbitrated request valid |
| `arb_ready` | in | 1 | Downstream (cmd_scheduler) ready to accept |
| `arb_is_write` | out | 1 | `1` = write request, `0` = read request |
| `arb_addr` | out | AXI_ADDR_W | Selected address |
| `arb_id` | out | AXI_ID_W | Selected transaction ID |

---

## FSM Description

```
       rst_n = 0
            |
            v
       +--------+
       |  IDLE  |<--------------------------+
       +---+----+                           |
           | grant_rd or grant_wr           |
           | (not blocked by ref_req)       |
           v                                |
       +--------+    arb_ready = 1          |
       |  BUSY  |---------------------------+
       +--------+
```

- **IDLE**: Evaluates `rd_valid`, `wr_valid`, and `ref_req`.  If
  `ref_req = 0` and at least one request is pending, the winning request
  is latched and `arb_valid` is asserted; the arbiter moves to BUSY.
- **BUSY**: Holds `arb_valid` until `arb_ready` is observed from
  `cmd_scheduler`.  In-flight BUSY transactions are not aborted by
  `ref_req` (refresh observes tRAS/tWR timing naturally via
  `timing_ctrl`).

### Priority Selection

```
prefer_rd = (RD_PRIORITY == 1)

grant_rd =  can_arb && rd_valid && (!wr_valid ||  prefer_rd)
grant_wr =  can_arb && wr_valid && (!rd_valid || !prefer_rd)
```

`can_arb = (state == IDLE) && !ref_req`

When only one channel has a pending request it is always granted regardless
of `RD_PRIORITY`.

---

## Reset Behavior

All outputs (`arb_valid`, `rd_ready`, `wr_ready`) are de-asserted
synchronously on the cycle after `rst_n` de-asserts.  The reset is
**asynchronous** (negedge `rst_n` in the sensitivity list), consistent with
the rest of the DDR4 controller.

---

## Files

| Role | Path |
|---|---|
| RTL | `rtl/cmd_arbiter.v` |
| Testbench | `tb/cmd_arbiter_tb.v` |
| Results | `results/phase-ddr4-sched/` |
