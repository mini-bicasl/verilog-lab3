# `ecc_decoder` – SECDED (72,64) Hamming Decoder

## Overview

`ecc_decoder` implements the **receive side** of the SECDED (72,64) Hamming code used in the DDR4 controller read path (see `docs/ARCHITECTURE.md §4.3`).  It takes the 72-bit codeword returned by DRAM, corrects any single-bit error transparently, detects any double-bit error, and forwards corrected 64-bit data to the AXI read channel.

The module is **purely combinational** – no registers, clock, or reset.

---

## Interface

| Port | Direction | Width | Description |
|---|---|---|---|
| `dec_word_in` | in | 72 | 72-bit codeword from DRAM (potentially corrupted) |
| `dec_data_out` | out | 64 | Corrected 64-bit data |
| `dec_single_err` | out | 1 | 1 = single-bit error detected and corrected |
| `dec_double_err` | out | 1 | 1 = double-bit error detected (uncorrectable) |
| `dec_syndrome` | out | 8 | Raw syndrome `{overall_parity, syndrome[6:0]}` for diagnostics |

The input word is packed identically to the encoder output:

```
dec_word_in[71:64] = received check bits  cb_r[7:0]
dec_word_in[63:0]  = received data bits   d_r[63:0]
```

---

## Algorithm

### Syndrome Computation

For each Hamming parity bit `k` (0–6), the syndrome bit is:

```
syndrome[k] = cb_r[k] XOR (even parity of all d_r[i] in parity group k)
```

If the received codeword is error-free, `syndrome[6:0] = 0`.  A non-zero value encodes the **logical Hamming position** of the corrupted bit.

The eighth syndrome bit is the **overall parity** of all 72 received bits:

```
syndrome[7] = XOR of dec_word_in[71:0]
```

### Error Classification

| `syndrome[7]` | `syndrome[6:0]` | Meaning |
|---|---|---|
| 0 | 0 | No error |
| 1 | any | Single-bit error at logical position `syndrome[6:0]`; correct if a data bit |
| 0 | ≠ 0 | Double-bit error – detected but uncorrectable |

`dec_single_err = syndrome[7]`  
`dec_double_err = (syndrome[6:0] ≠ 0) AND NOT syndrome[7]`

### Single-Bit Correction

When `dec_single_err = 1` and `syndrome[6:0] ≠ 0`:

- **Power-of-2 syndrome** (1, 2, 4, 8, 16, 32, 64): error is in a check bit; `dec_data_out = d_r` (no data correction needed).
- **Other values** (3, 5, 6, 7, 9–15, 17–31, 33–63, 65–71): error is in a data bit.  The bit index is looked up via the inverse position table and flipped.

When `dec_single_err = 1` and `syndrome[6:0] = 0`: error is in the overall-parity check bit `cb[7]`; data is correct.

---

## FSM / Control

No FSM – purely combinational pipeline:

```
dec_word_in
    |
    +--> syndrome computation (XOR trees)
    |         |
    |         +--> dec_syndrome[7:0]
    |         +--> dec_single_err
    |         +--> dec_double_err
    |         +--> correction mask (case on syndrome[6:0])
    |
    +--> d_r XOR correction_mask --> dec_data_out
```

---

## Key Constraints

- No clock or reset; purely combinational.
- `dec_double_err` is asserted on uncorrectable errors; the `axi4_slave` sets `s_axi_rresp = SLVERR` in response (see `docs/ARCHITECTURE.md §4.5`).
- `dec_single_err` is pulsed for error logging; the address is available from the AXI transaction context.

---

## Files

| File | Description |
|---|---|
| `rtl/ecc_decoder.v` | Synthesizable RTL |
| `tb/ecc_decoder_tb.v` | Directed testbench (128 checks: all 72 single-bit error positions + double-bit samples + round-trips) |
| `results/phase-ddr4-ecc/ecc_decoder_sim.log` | Simulation log |
| `results/phase-ddr4-ecc/ecc_decoder.vcd` | Waveform dump |
