// ecc_encoder.v – SECDED (72,64) Hamming encoder
//
// Generates 8 check bits for a 64-bit data word using a standard
// Single-Error-Correcting, Double-Error-Detecting (SECDED) code.
//
// Data bits d[0..63] occupy non-power-of-2 positions 1..71 in the
// logical Hamming codeword.  Check bits cb[0..6] sit at the seven
// power-of-2 positions (1, 2, 4, 8, 16, 32, 64) and cb[7] is an
// overall parity bit that enables double-error detection.
//
// Interface (from docs/ARCHITECTURE.md §3.4):
//   enc_data_in  [63:0]  – raw 64-bit write data
//   enc_check_out [7:0]  – 8 SECDED check bits
//   enc_word_out [71:0]  – {enc_check_out, enc_data_in}
//
// Purely combinational – no clock or reset required.

`default_nettype none

module ecc_encoder (
    input  wire [63:0] enc_data_in,
    output wire [7:0]  enc_check_out,
    output wire [71:0] enc_word_out
);

    // ---------------------------------------------------------------
    // Check bit generation
    // Each cb[k] (k=0..6) is the even-parity bit over all data bits
    // whose logical Hamming position has bit k set.
    // Logical positions of d[0]..d[63]:
    //   d[0..3]   -> 3, 5, 6, 7
    //   d[4..10]  -> 9..15
    //   d[11..25] -> 17..31
    //   d[26..56] -> 33..63
    //   d[57..63] -> 65..71
    // ---------------------------------------------------------------

    // cb[0]: covers positions where bit 0 is set (odd positions 3,5,7,…,71)
    assign enc_check_out[0] =
        enc_data_in[0]  ^ enc_data_in[1]  ^ enc_data_in[3]  ^ enc_data_in[4]  ^
        enc_data_in[6]  ^ enc_data_in[8]  ^ enc_data_in[10] ^ enc_data_in[11] ^
        enc_data_in[13] ^ enc_data_in[15] ^ enc_data_in[17] ^ enc_data_in[19] ^
        enc_data_in[21] ^ enc_data_in[23] ^ enc_data_in[25] ^ enc_data_in[26] ^
        enc_data_in[28] ^ enc_data_in[30] ^ enc_data_in[32] ^ enc_data_in[34] ^
        enc_data_in[36] ^ enc_data_in[38] ^ enc_data_in[40] ^ enc_data_in[42] ^
        enc_data_in[44] ^ enc_data_in[46] ^ enc_data_in[48] ^ enc_data_in[50] ^
        enc_data_in[52] ^ enc_data_in[54] ^ enc_data_in[56] ^ enc_data_in[57] ^
        enc_data_in[59] ^ enc_data_in[61] ^ enc_data_in[63];

    // cb[1]: covers positions where bit 1 is set
    assign enc_check_out[1] =
        enc_data_in[0]  ^ enc_data_in[2]  ^ enc_data_in[3]  ^ enc_data_in[5]  ^
        enc_data_in[6]  ^ enc_data_in[9]  ^ enc_data_in[10] ^ enc_data_in[12] ^
        enc_data_in[13] ^ enc_data_in[16] ^ enc_data_in[17] ^ enc_data_in[20] ^
        enc_data_in[21] ^ enc_data_in[24] ^ enc_data_in[25] ^ enc_data_in[27] ^
        enc_data_in[28] ^ enc_data_in[31] ^ enc_data_in[32] ^ enc_data_in[35] ^
        enc_data_in[36] ^ enc_data_in[39] ^ enc_data_in[40] ^ enc_data_in[43] ^
        enc_data_in[44] ^ enc_data_in[47] ^ enc_data_in[48] ^ enc_data_in[51] ^
        enc_data_in[52] ^ enc_data_in[55] ^ enc_data_in[56] ^ enc_data_in[58] ^
        enc_data_in[59] ^ enc_data_in[62] ^ enc_data_in[63];

    // cb[2]: covers positions where bit 2 is set
    assign enc_check_out[2] =
        enc_data_in[1]  ^ enc_data_in[2]  ^ enc_data_in[3]  ^ enc_data_in[7]  ^
        enc_data_in[8]  ^ enc_data_in[9]  ^ enc_data_in[10] ^ enc_data_in[14] ^
        enc_data_in[15] ^ enc_data_in[16] ^ enc_data_in[17] ^ enc_data_in[22] ^
        enc_data_in[23] ^ enc_data_in[24] ^ enc_data_in[25] ^ enc_data_in[29] ^
        enc_data_in[30] ^ enc_data_in[31] ^ enc_data_in[32] ^ enc_data_in[37] ^
        enc_data_in[38] ^ enc_data_in[39] ^ enc_data_in[40] ^ enc_data_in[45] ^
        enc_data_in[46] ^ enc_data_in[47] ^ enc_data_in[48] ^ enc_data_in[53] ^
        enc_data_in[54] ^ enc_data_in[55] ^ enc_data_in[56] ^ enc_data_in[60] ^
        enc_data_in[61] ^ enc_data_in[62] ^ enc_data_in[63];

    // cb[3]: covers positions where bit 3 is set (ranges 9-15, 24-31, 40-47, 56-63)
    assign enc_check_out[3] =
        enc_data_in[4]  ^ enc_data_in[5]  ^ enc_data_in[6]  ^ enc_data_in[7]  ^
        enc_data_in[8]  ^ enc_data_in[9]  ^ enc_data_in[10] ^ enc_data_in[18] ^
        enc_data_in[19] ^ enc_data_in[20] ^ enc_data_in[21] ^ enc_data_in[22] ^
        enc_data_in[23] ^ enc_data_in[24] ^ enc_data_in[25] ^ enc_data_in[33] ^
        enc_data_in[34] ^ enc_data_in[35] ^ enc_data_in[36] ^ enc_data_in[37] ^
        enc_data_in[38] ^ enc_data_in[39] ^ enc_data_in[40] ^ enc_data_in[49] ^
        enc_data_in[50] ^ enc_data_in[51] ^ enc_data_in[52] ^ enc_data_in[53] ^
        enc_data_in[54] ^ enc_data_in[55] ^ enc_data_in[56];

    // cb[4]: covers positions where bit 4 is set (ranges 17-31, 48-63)
    assign enc_check_out[4] =
        enc_data_in[11] ^ enc_data_in[12] ^ enc_data_in[13] ^ enc_data_in[14] ^
        enc_data_in[15] ^ enc_data_in[16] ^ enc_data_in[17] ^ enc_data_in[18] ^
        enc_data_in[19] ^ enc_data_in[20] ^ enc_data_in[21] ^ enc_data_in[22] ^
        enc_data_in[23] ^ enc_data_in[24] ^ enc_data_in[25] ^ enc_data_in[41] ^
        enc_data_in[42] ^ enc_data_in[43] ^ enc_data_in[44] ^ enc_data_in[45] ^
        enc_data_in[46] ^ enc_data_in[47] ^ enc_data_in[48] ^ enc_data_in[49] ^
        enc_data_in[50] ^ enc_data_in[51] ^ enc_data_in[52] ^ enc_data_in[53] ^
        enc_data_in[54] ^ enc_data_in[55] ^ enc_data_in[56];

    // cb[5]: covers positions where bit 5 is set (range 33-63)
    assign enc_check_out[5] =
        enc_data_in[26] ^ enc_data_in[27] ^ enc_data_in[28] ^ enc_data_in[29] ^
        enc_data_in[30] ^ enc_data_in[31] ^ enc_data_in[32] ^ enc_data_in[33] ^
        enc_data_in[34] ^ enc_data_in[35] ^ enc_data_in[36] ^ enc_data_in[37] ^
        enc_data_in[38] ^ enc_data_in[39] ^ enc_data_in[40] ^ enc_data_in[41] ^
        enc_data_in[42] ^ enc_data_in[43] ^ enc_data_in[44] ^ enc_data_in[45] ^
        enc_data_in[46] ^ enc_data_in[47] ^ enc_data_in[48] ^ enc_data_in[49] ^
        enc_data_in[50] ^ enc_data_in[51] ^ enc_data_in[52] ^ enc_data_in[53] ^
        enc_data_in[54] ^ enc_data_in[55] ^ enc_data_in[56];

    // cb[6]: covers positions where bit 6 is set (range 65-71 = d[57..63])
    assign enc_check_out[6] =
        enc_data_in[57] ^ enc_data_in[58] ^ enc_data_in[59] ^ enc_data_in[60] ^
        enc_data_in[61] ^ enc_data_in[62] ^ enc_data_in[63];

    // cb[7]: overall parity over all 71 bits (data + cb[6:0])
    assign enc_check_out[7] = ^enc_data_in ^ ^enc_check_out[6:0];

    // Output word: {check_bits[7:0], data[63:0]}
    assign enc_word_out = {enc_check_out, enc_data_in};

endmodule

`default_nettype wire
