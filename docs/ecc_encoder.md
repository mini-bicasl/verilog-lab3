# `ecc_encoder` – SECDED (72,64) Hamming Encoder

## Overview

`ecc_encoder` generates the 8 check bits required by the **SECDED (Single-Error Correcting, Double-Error Detecting)** code used throughout the DDR4 controller write path (see `docs/ARCHITECTURE.md §4.3`).  It takes a raw 64-bit data word from the AXI write channel and produces the 72-bit codeword that is written to DRAM.

The module is **purely combinational** – it contains no registers, clocks, or resets.

---

## Interface

| Port | Direction | Width | Description |
|---|---|---|---|
| `enc_data_in` | in | 64 | Raw 64-bit write data from AXI |
| `enc_check_out` | out | 8 | 8 SECDED check bits (cb[7:0]) |
| `enc_word_out` | out | 72 | `{enc_check_out, enc_data_in}` – codeword written to DRAM |

---

## ECC Scheme

The encoder implements the standard **SECDED (72,64) Hamming code** as used by JEDEC DDR4 devices.

### Bit Position Mapping

The 64 data bits occupy the 64 **non-power-of-2** positions within a logical 71-bit Hamming codeword (positions 1 through 71).  The seven **power-of-2** positions (1, 2, 4, 8, 16, 32, 64) are reserved for parity check bits `cb[0]`..`cb[6]`.  An eighth overall-parity bit `cb[7]` enables double-error detection.

| Data bits | Logical Hamming positions |
|---|---|
| `d[0..3]` | 3, 5, 6, 7 |
| `d[4..10]` | 9 – 15 |
| `d[11..25]` | 17 – 31 |
| `d[26..56]` | 33 – 63 |
| `d[57..63]` | 65 – 71 |

### Check Bit Generation

Each of the first seven check bits is the **even parity** of all data bits whose logical Hamming position has the corresponding bit set:

| Check bit | Power-of-2 position | Covers data bits whose position has bit `k` set |
|---|---|---|
| `cb[0]` | 1 | Positions 3,5,7,9,11,… (35 data bits) |
| `cb[1]` | 2 | Positions 3,6,7,10,11,… (35 data bits) |
| `cb[2]` | 4 | Positions 5,6,7,12,13,… (35 data bits) |
| `cb[3]` | 8 | Positions 9–15, 24–31, 40–47, 56–63 (31 data bits) |
| `cb[4]` | 16 | Positions 17–31, 48–63 (31 data bits) |
| `cb[5]` | 32 | Positions 33–63 (31 data bits) |
| `cb[6]` | 64 | Positions 65–71 = `d[57..63]` (7 data bits) |
| `cb[7]` | — | XOR of all 64 data bits and `cb[6:0]` (overall parity) |

The output codeword is packed as:

```
enc_word_out[71:64] = cb[7:0]   (check bits)
enc_word_out[63:0]  = d[63:0]   (data, unchanged)
```

---

## Known-Good Test Vectors

| `enc_data_in` | `enc_check_out` |
|---|---|
| `64'h0000000000000000` | `8'h00` |
| `64'hFFFFFFFFFFFFFFFF` | `8'hFF` |
| `64'hDEADBEEFCAFEBABE` | `8'h3A` |
| `64'h0000000000000001` | `8'h83` |
| `64'h8000000000000000` | `8'hC7` |
| `64'h5555555555555555` | `8'h55` |
| `64'hAAAAAAAAAAAAAAAA` | `8'hAA` |

---

## Key Constraints

- Purely combinational; propagation delay is one XOR tree level through up to 35 inputs.
- No timing requirements (no setup/hold); can be placed directly on the write data path.

---

## Files

| File | Description |
|---|---|
| `rtl/ecc_encoder.v` | Synthesizable RTL |
| `tb/ecc_encoder_tb.v` | Directed testbench (73 checks: 64 single-bit patterns + vectors) |
| `results/phase-ddr4-ecc/ecc_encoder_sim.log` | Simulation log |
| `results/phase-ddr4-ecc/ecc_encoder.vcd` | Waveform dump |
