# DDR4 Controller Implementation Plan

This file is the **authoritative implementation checklist** for the DDR4
controller project.  Phase names are used as directory names under `results/`.

---

## Phase 1: ECC – `phase-ddr4-ecc`

Implement and verify the standalone ECC encode/decode pair first since every
other module depends on correct ECC data.

### RTL Modules

- [ ] `ecc_encoder`: RTL implementation (`rtl/ecc_encoder.v`)
- [ ] `ecc_decoder`: RTL implementation (`rtl/ecc_decoder.v`)

### Testbenches

- [ ] `ecc_encoder`: Testbench (`tb/ecc_encoder_tb.v`)
- [ ] `ecc_decoder`: Testbench (`tb/ecc_decoder_tb.v`)

### Documentation

- [ ] `ecc_encoder`: Module documentation (`docs/ecc_encoder.md`)
- [ ] `ecc_decoder`: Module documentation (`docs/ecc_decoder.md`)

### Verification / Coverage

- [ ] `ecc_encoder`: All 64 single-bit injection patterns pass
- [ ] `ecc_decoder`: All single-bit errors corrected; all double-bit errors detected

---

## Phase 2: Bank FSM – `phase-ddr4-bank`

Implement the per-bank state machine; used by the scheduler in later phases.

### RTL Modules

- [ ] `bank_fsm`: RTL implementation (`rtl/bank_fsm.v`)

### Testbenches

- [ ] `bank_fsm`: Testbench (`tb/bank_fsm_tb.v`)

### Documentation

- [ ] `bank_fsm`: Module documentation (`docs/bank_fsm.md`)

### Verification / Coverage

- [ ] `bank_fsm`: All state transitions (IDLE->ACTIVATING->ACTIVE->PRECHARGING->IDLE)
- [ ] `bank_fsm`: tRAS enforcement; illegal transitions blocked

---

## Phase 3: Timing Controller – `phase-ddr4-timing`

Implement the timing constraint enforcer.  This module is purely combinational
(or uses counters); it blocks commands that violate JEDEC timing.

### RTL Modules

- [ ] `timing_ctrl`: RTL implementation (`rtl/timing_ctrl.v`)

### Testbenches

- [ ] `timing_ctrl`: Testbench (`tb/timing_ctrl_tb.v`)

### Documentation

- [ ] `timing_ctrl`: Module documentation (`docs/timing_ctrl.md`)

### Verification / Coverage

- [ ] `timing_ctrl`: tRCD, tRP, tRAS, tRC, tRRD_S, tRRD_L, tCCD_S, tCCD_L, tFAW
- [ ] `timing_ctrl`: tWTR_S, tWTR_L, tRTP, tWR

---

## Phase 4: Refresh Controller – `phase-ddr4-refresh`

### RTL Modules

- [ ] `refresh_ctrl`: RTL implementation (`rtl/refresh_ctrl.v`)

### Testbenches

- [ ] `refresh_ctrl`: Testbench (`tb/refresh_ctrl_tb.v`)

### Documentation

- [ ] `refresh_ctrl`: Module documentation (`docs/refresh_ctrl.md`)

### Verification / Coverage

- [ ] `refresh_ctrl`: REFab issued at tREFI intervals
- [ ] `refresh_ctrl`: tRFC stall observed after every refresh
- [ ] `refresh_ctrl`: REFpb mode cycles through all banks

---

## Phase 5: Command Arbiter & Scheduler – `phase-ddr4-sched`

### RTL Modules

- [ ] `cmd_arbiter`: RTL implementation (`rtl/cmd_arbiter.v`)
- [ ] `cmd_scheduler`: RTL implementation (`rtl/cmd_scheduler.v`)

### Testbenches

- [ ] `cmd_arbiter`: Testbench (`tb/cmd_arbiter_tb.v`)
- [ ] `cmd_scheduler`: Testbench (`tb/cmd_scheduler_tb.v`)

### Documentation

- [ ] `cmd_arbiter`: Module documentation (`docs/cmd_arbiter.md`)
- [ ] `cmd_scheduler`: Module documentation (`docs/cmd_scheduler.md`)

### Verification / Coverage

- [ ] `cmd_scheduler`: Open-row hit generates READ/WRITE without ACT
- [ ] `cmd_scheduler`: Row miss generates PRECHARGE -> ACTIVATE -> READ/WRITE
- [ ] `cmd_scheduler`: Refresh preempts normal traffic

---

## Phase 6: AXI4 Slave Interface – `phase-ddr4-axi`

### RTL Modules

- [ ] `axi4_slave`: RTL implementation (`rtl/axi4_slave.v`)

### Testbenches

- [ ] `axi4_slave`: Testbench (`tb/axi4_slave_tb.v`)

### Documentation

- [ ] `axi4_slave`: Module documentation (`docs/axi4_slave.md`)

### Verification / Coverage

- [ ] `axi4_slave`: Single write then read round-trip
- [ ] `axi4_slave`: Out-of-order IDs; back-pressure on WREADY/ARREADY
- [ ] `axi4_slave`: SLVERR on double-bit ECC error

---

## Phase 7: PHY Interface – `phase-ddr4-phy`

### RTL Modules

- [ ] `phy_if`: RTL implementation (`rtl/phy_if.v`)

### Testbenches

- [ ] `phy_if`: Testbench (`tb/phy_if_tb.v`)

### Documentation

- [ ] `phy_if`: Module documentation (`docs/phy_if.md`)

### Verification / Coverage

- [ ] `phy_if`: DQ tristate direction control
- [ ] `phy_if`: DQS pre-amble / post-amble waveforms

---

## Phase 8: Top-Level Integration – `phase-ddr4-top`

### RTL Modules

- [ ] `ddr4_ctrl_top`: RTL implementation (`rtl/ddr4_ctrl_top.v`)

### Testbenches

- [ ] `ddr4_ctrl_top`: Integration testbench (`tb/ddr4_ctrl_top_tb.v`)

### Documentation

- [ ] `ddr4_ctrl_top`: Module documentation (`docs/ddr4_ctrl_top.md`)

### Verification / Coverage

- [ ] `ddr4_ctrl_top`: Full write/read path with ECC injection
- [ ] `ddr4_ctrl_top`: Refresh interleaved with normal traffic
- [ ] `ddr4_ctrl_top`: Multi-bank parallel access

---

## JSON Traceability

Results for each phase are stored under `results/phase-<phase_name>/` with
one `<module>_result.json` per module.  Required keys:

- `module`, `rtl_done`, `tb_done`, `doc_done`
- `simulation_passed` (true only after successful `vvp` run)
- `coverage_completed`, `coverage_percentage`
- `plan_item_completed`
- `error_summary` (empty string when passing)
