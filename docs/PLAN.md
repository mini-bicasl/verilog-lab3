# DDR4 Controller Implementation Plan

This file is the **authoritative implementation checklist** for the DDR4
controller project.  Phase names are used as directory names under `results/`.

---

## Phase 1: ECC – `phase-ddr4-ecc`

Implement and verify the standalone ECC encode/decode pair first since every
other module depends on correct ECC data.

### RTL Modules

- [x] `ecc_encoder`: RTL implementation (`rtl/ecc_encoder.v`)
- [x] `ecc_decoder`: RTL implementation (`rtl/ecc_decoder.v`)

### Testbenches

- [x] `ecc_encoder`: Testbench (`tb/ecc_encoder_tb.v`)
- [x] `ecc_decoder`: Testbench (`tb/ecc_decoder_tb.v`)

### Documentation

- [x] `ecc_encoder`: Module documentation (`docs/ecc_encoder.md`)
- [x] `ecc_decoder`: Module documentation (`docs/ecc_decoder.md`)

### Verification / Coverage

- [x] `ecc_encoder`: All 64 single-bit injection patterns pass
- [x] `ecc_decoder`: All single-bit errors corrected; all double-bit errors detected

---

## Phase 2: Bank FSM – `phase-ddr4-bank`

Implement the per-bank state machine; used by the scheduler in later phases.

### RTL Modules

- [x] `bank_fsm`: RTL implementation (`rtl/bank_fsm.v`)

### Testbenches

- [x] `bank_fsm`: Testbench (`tb/bank_fsm_tb.v`)

### Documentation

- [x] `bank_fsm`: Module documentation (`docs/bank_fsm.md`)

### Verification / Coverage

- [x] `bank_fsm`: All state transitions (IDLE->ACTIVATING->ACTIVE->PRECHARGING->IDLE)
- [x] `bank_fsm`: tRAS enforcement; illegal transitions blocked

---

## Phase 3: Timing Controller – `phase-ddr4-timing`

Implement the timing constraint enforcer.  This module is purely combinational
(or uses counters); it blocks commands that violate JEDEC timing.

### RTL Modules

- [x] `timing_ctrl`: RTL implementation (`rtl/timing_ctrl.v`)

### Testbenches

- [x] `timing_ctrl`: Testbench (`tb/timing_ctrl_tb.v`)

### Documentation

- [x] `timing_ctrl`: Module documentation (`docs/timing_ctrl.md`)

### Verification / Coverage

- [x] `timing_ctrl`: tRCD, tRP, tRAS, tRC, tRRD_S, tRRD_L, tCCD_S, tCCD_L, tFAW
- [x] `timing_ctrl`: tWTR_S, tWTR_L, tRTP, tWR

---

## Phase 4: Refresh Controller – `phase-ddr4-refresh`

### RTL Modules

- [x] `refresh_ctrl`: RTL implementation (`rtl/refresh_ctrl.v`)

### Testbenches

- [x] `refresh_ctrl`: Testbench (`tb/refresh_ctrl_tb.v`)

### Documentation

- [x] `refresh_ctrl`: Module documentation (`docs/refresh_ctrl.md`)

### Verification / Coverage

- [x] `refresh_ctrl`: REFab issued at tREFI intervals
- [x] `refresh_ctrl`: tRFC stall observed after every refresh
- [x] `refresh_ctrl`: REFpb mode cycles through all banks

---

## Phase 5: Command Arbiter & Scheduler – `phase-ddr4-sched`

### RTL Modules

- [x] `cmd_arbiter`: RTL implementation (`rtl/cmd_arbiter.v`)
- [x] `cmd_scheduler`: RTL implementation (`rtl/cmd_scheduler.v`)

### Testbenches

- [x] `cmd_arbiter`: Testbench (`tb/cmd_arbiter_tb.v`)
- [x] `cmd_scheduler`: Testbench (`tb/cmd_scheduler_tb.v`)

### Documentation

- [x] `cmd_arbiter`: Module documentation (`docs/cmd_arbiter.md`)
- [x] `cmd_scheduler`: Module documentation (`docs/cmd_scheduler.md`)

### Verification / Coverage

- [x] `cmd_scheduler`: Open-row hit generates READ/WRITE without ACT
- [x] `cmd_scheduler`: Row miss generates PRECHARGE -> ACTIVATE -> READ/WRITE
- [x] `cmd_scheduler`: Refresh preempts normal traffic

---

## Phase 6: AXI4 Slave Interface – `phase-ddr4-axi`

### RTL Modules

- [x] `axi4_slave`: RTL implementation (`rtl/axi4_slave.v`)

### Testbenches

- [x] `axi4_slave`: Testbench (`tb/axi4_slave_tb.v`)

### Documentation

- [x] `axi4_slave`: Module documentation (`docs/axi4_slave.md`)

### Verification / Coverage

- [x] `axi4_slave`: Single write then read round-trip
- [x] `axi4_slave`: Out-of-order IDs; back-pressure on WREADY/ARREADY
- [x] `axi4_slave`: SLVERR on double-bit ECC error

---

## Phase 7: PHY Interface – `phase-ddr4-phy`

### RTL Modules

- [x] `phy_if`: RTL implementation (`rtl/phy_if.v`)

### Testbenches

- [x] `phy_if`: Testbench (`tb/phy_if_tb.v`)

### Documentation

- [x] `phy_if`: Module documentation (`docs/phy_if.md`)

### Verification / Coverage

- [x] `phy_if`: DQ tristate direction control
- [x] `phy_if`: DQS pre-amble / post-amble waveforms

---

## Phase 8: Top-Level Integration – `phase-ddr4-top`

### RTL Modules

- [x] `ddr4_ctrl_top`: RTL implementation (`rtl/ddr4_ctrl_top.v`)

### Testbenches

- [x] `ddr4_ctrl_top`: Integration testbench (`tb/ddr4_ctrl_top_tb.v`)

### Documentation

- [x] `ddr4_ctrl_top`: Module documentation (`docs/ddr4_ctrl_top.md`)

### Verification / Coverage

- [x] `ddr4_ctrl_top`: Full write/read path with ECC injection (19 PASSED, 0 FAILED)
- [x] `ddr4_ctrl_top`: Refresh controller tREFI countdown verified
- [x] `ddr4_ctrl_top`: Multi-bank access (bg=0/bank=0, bg=1/bank=1, bg=2/bank=2)

---

## JSON Traceability

Results for each phase are stored under `results/phase-<phase_name>/` with
one `<module>_result.json` per module.  Required keys:

- `module`, `rtl_done`, `tb_done`, `doc_done`
- `simulation_passed` (true only after successful `vvp` run)
- `coverage_completed`, `coverage_percentage`
- `plan_item_completed`
- `error_summary` (empty string when passing)
