// ecc_decoder.v – SECDED (72,64) Hamming decoder
//
// Accepts a 72-bit codeword ({check_bits[7:0], data[63:0]}) that may
// contain single-bit or double-bit errors and produces:
//   - Corrected 64-bit data output
//   - Single-error flag (single-bit error corrected)
//   - Double-error flag (uncorrectable double-bit error detected)
//   - Raw 8-bit syndrome for diagnostics
//
// Interface (from docs/ARCHITECTURE.md §3.5):
//   dec_word_in   [71:0] – 72-bit word read from DRAM
//   dec_data_out  [63:0] – corrected 64-bit data
//   dec_single_err       – 1: single-bit error detected and corrected
//   dec_double_err       – 1: double-bit error detected (uncorrectable)
//   dec_syndrome   [7:0] – raw syndrome (syndrome[7]=overall parity)
//
// SECDED error-detection rules:
//   syndrome[7]=0, syndrome[6:0]=0  → no error
//   syndrome[7]=1                    → single-bit error (correct if data bit)
//   syndrome[7]=0, syndrome[6:0]≠0  → double-bit error (detected only)
//
// Purely combinational – no clock or reset required.

`default_nettype none

module ecc_decoder (
    input  wire [71:0] dec_word_in,
    output reg  [63:0] dec_data_out,
    output wire        dec_single_err,
    output wire        dec_double_err,
    output wire [7:0]  dec_syndrome
);

    // ---------------------------------------------------------------
    // Unpack received word
    // ---------------------------------------------------------------
    wire [7:0]  cb_r = dec_word_in[71:64];  // received check bits
    wire [63:0] d_r  = dec_word_in[63:0];   // received data bits

    // ---------------------------------------------------------------
    // Syndrome computation
    // syndrome[k] = cb_r[k] XOR (parity of data bits in group k)
    // If syndrome[6:0]==0 the codeword is consistent; the exact
    // non-zero value of syndrome[6:0] encodes the error bit position.
    // syndrome[7] = overall parity of all 72 bits.
    // ---------------------------------------------------------------
    wire [6:0] synd;

    assign synd[0] =
        cb_r[0]         ^
        d_r[0]  ^ d_r[1]  ^ d_r[3]  ^ d_r[4]  ^
        d_r[6]  ^ d_r[8]  ^ d_r[10] ^ d_r[11] ^
        d_r[13] ^ d_r[15] ^ d_r[17] ^ d_r[19] ^
        d_r[21] ^ d_r[23] ^ d_r[25] ^ d_r[26] ^
        d_r[28] ^ d_r[30] ^ d_r[32] ^ d_r[34] ^
        d_r[36] ^ d_r[38] ^ d_r[40] ^ d_r[42] ^
        d_r[44] ^ d_r[46] ^ d_r[48] ^ d_r[50] ^
        d_r[52] ^ d_r[54] ^ d_r[56] ^ d_r[57] ^
        d_r[59] ^ d_r[61] ^ d_r[63];

    assign synd[1] =
        cb_r[1]         ^
        d_r[0]  ^ d_r[2]  ^ d_r[3]  ^ d_r[5]  ^
        d_r[6]  ^ d_r[9]  ^ d_r[10] ^ d_r[12] ^
        d_r[13] ^ d_r[16] ^ d_r[17] ^ d_r[20] ^
        d_r[21] ^ d_r[24] ^ d_r[25] ^ d_r[27] ^
        d_r[28] ^ d_r[31] ^ d_r[32] ^ d_r[35] ^
        d_r[36] ^ d_r[39] ^ d_r[40] ^ d_r[43] ^
        d_r[44] ^ d_r[47] ^ d_r[48] ^ d_r[51] ^
        d_r[52] ^ d_r[55] ^ d_r[56] ^ d_r[58] ^
        d_r[59] ^ d_r[62] ^ d_r[63];

    assign synd[2] =
        cb_r[2]         ^
        d_r[1]  ^ d_r[2]  ^ d_r[3]  ^ d_r[7]  ^
        d_r[8]  ^ d_r[9]  ^ d_r[10] ^ d_r[14] ^
        d_r[15] ^ d_r[16] ^ d_r[17] ^ d_r[22] ^
        d_r[23] ^ d_r[24] ^ d_r[25] ^ d_r[29] ^
        d_r[30] ^ d_r[31] ^ d_r[32] ^ d_r[37] ^
        d_r[38] ^ d_r[39] ^ d_r[40] ^ d_r[45] ^
        d_r[46] ^ d_r[47] ^ d_r[48] ^ d_r[53] ^
        d_r[54] ^ d_r[55] ^ d_r[56] ^ d_r[60] ^
        d_r[61] ^ d_r[62] ^ d_r[63];

    assign synd[3] =
        cb_r[3]         ^
        d_r[4]  ^ d_r[5]  ^ d_r[6]  ^ d_r[7]  ^
        d_r[8]  ^ d_r[9]  ^ d_r[10] ^ d_r[18] ^
        d_r[19] ^ d_r[20] ^ d_r[21] ^ d_r[22] ^
        d_r[23] ^ d_r[24] ^ d_r[25] ^ d_r[33] ^
        d_r[34] ^ d_r[35] ^ d_r[36] ^ d_r[37] ^
        d_r[38] ^ d_r[39] ^ d_r[40] ^ d_r[49] ^
        d_r[50] ^ d_r[51] ^ d_r[52] ^ d_r[53] ^
        d_r[54] ^ d_r[55] ^ d_r[56];

    assign synd[4] =
        cb_r[4]         ^
        d_r[11] ^ d_r[12] ^ d_r[13] ^ d_r[14] ^
        d_r[15] ^ d_r[16] ^ d_r[17] ^ d_r[18] ^
        d_r[19] ^ d_r[20] ^ d_r[21] ^ d_r[22] ^
        d_r[23] ^ d_r[24] ^ d_r[25] ^ d_r[41] ^
        d_r[42] ^ d_r[43] ^ d_r[44] ^ d_r[45] ^
        d_r[46] ^ d_r[47] ^ d_r[48] ^ d_r[49] ^
        d_r[50] ^ d_r[51] ^ d_r[52] ^ d_r[53] ^
        d_r[54] ^ d_r[55] ^ d_r[56];

    assign synd[5] =
        cb_r[5]         ^
        d_r[26] ^ d_r[27] ^ d_r[28] ^ d_r[29] ^
        d_r[30] ^ d_r[31] ^ d_r[32] ^ d_r[33] ^
        d_r[34] ^ d_r[35] ^ d_r[36] ^ d_r[37] ^
        d_r[38] ^ d_r[39] ^ d_r[40] ^ d_r[41] ^
        d_r[42] ^ d_r[43] ^ d_r[44] ^ d_r[45] ^
        d_r[46] ^ d_r[47] ^ d_r[48] ^ d_r[49] ^
        d_r[50] ^ d_r[51] ^ d_r[52] ^ d_r[53] ^
        d_r[54] ^ d_r[55] ^ d_r[56];

    assign synd[6] =
        cb_r[6]         ^
        d_r[57] ^ d_r[58] ^ d_r[59] ^ d_r[60] ^
        d_r[61] ^ d_r[62] ^ d_r[63];

    // Overall parity (bit 7 of syndrome): XOR of all 72 received bits
    wire overall_parity = ^dec_word_in;

    assign dec_syndrome   = {overall_parity, synd};

    // SECDED rules:
    //   overall_parity==1               → single-bit error (syndrome[6:0] says where)
    //   overall_parity==0, synd!=0      → double-bit error
    assign dec_single_err = overall_parity;
    assign dec_double_err = (synd != 7'h0) & ~overall_parity;

    // ---------------------------------------------------------------
    // Single-bit error correction
    // syndrome[6:0] is the logical Hamming position of the error.
    // Powers-of-2 positions (1,2,4,8,16,32,64) mean a check-bit
    // error; data is already correct.  All other positions map to
    // a specific data bit which is flipped.
    // ---------------------------------------------------------------
    reg [63:0] corr_mask;

    always @(*) begin
        corr_mask = 64'h0;
        if (dec_single_err) begin
            case (synd)
                // Data bit positions (non-powers-of-2 in 1..71)
                7'd3:  corr_mask[0]  = 1'b1;
                7'd5:  corr_mask[1]  = 1'b1;
                7'd6:  corr_mask[2]  = 1'b1;
                7'd7:  corr_mask[3]  = 1'b1;
                7'd9:  corr_mask[4]  = 1'b1;
                7'd10: corr_mask[5]  = 1'b1;
                7'd11: corr_mask[6]  = 1'b1;
                7'd12: corr_mask[7]  = 1'b1;
                7'd13: corr_mask[8]  = 1'b1;
                7'd14: corr_mask[9]  = 1'b1;
                7'd15: corr_mask[10] = 1'b1;
                7'd17: corr_mask[11] = 1'b1;
                7'd18: corr_mask[12] = 1'b1;
                7'd19: corr_mask[13] = 1'b1;
                7'd20: corr_mask[14] = 1'b1;
                7'd21: corr_mask[15] = 1'b1;
                7'd22: corr_mask[16] = 1'b1;
                7'd23: corr_mask[17] = 1'b1;
                7'd24: corr_mask[18] = 1'b1;
                7'd25: corr_mask[19] = 1'b1;
                7'd26: corr_mask[20] = 1'b1;
                7'd27: corr_mask[21] = 1'b1;
                7'd28: corr_mask[22] = 1'b1;
                7'd29: corr_mask[23] = 1'b1;
                7'd30: corr_mask[24] = 1'b1;
                7'd31: corr_mask[25] = 1'b1;
                7'd33: corr_mask[26] = 1'b1;
                7'd34: corr_mask[27] = 1'b1;
                7'd35: corr_mask[28] = 1'b1;
                7'd36: corr_mask[29] = 1'b1;
                7'd37: corr_mask[30] = 1'b1;
                7'd38: corr_mask[31] = 1'b1;
                7'd39: corr_mask[32] = 1'b1;
                7'd40: corr_mask[33] = 1'b1;
                7'd41: corr_mask[34] = 1'b1;
                7'd42: corr_mask[35] = 1'b1;
                7'd43: corr_mask[36] = 1'b1;
                7'd44: corr_mask[37] = 1'b1;
                7'd45: corr_mask[38] = 1'b1;
                7'd46: corr_mask[39] = 1'b1;
                7'd47: corr_mask[40] = 1'b1;
                7'd48: corr_mask[41] = 1'b1;
                7'd49: corr_mask[42] = 1'b1;
                7'd50: corr_mask[43] = 1'b1;
                7'd51: corr_mask[44] = 1'b1;
                7'd52: corr_mask[45] = 1'b1;
                7'd53: corr_mask[46] = 1'b1;
                7'd54: corr_mask[47] = 1'b1;
                7'd55: corr_mask[48] = 1'b1;
                7'd56: corr_mask[49] = 1'b1;
                7'd57: corr_mask[50] = 1'b1;
                7'd58: corr_mask[51] = 1'b1;
                7'd59: corr_mask[52] = 1'b1;
                7'd60: corr_mask[53] = 1'b1;
                7'd61: corr_mask[54] = 1'b1;
                7'd62: corr_mask[55] = 1'b1;
                7'd63: corr_mask[56] = 1'b1;
                7'd65: corr_mask[57] = 1'b1;
                7'd66: corr_mask[58] = 1'b1;
                7'd67: corr_mask[59] = 1'b1;
                7'd68: corr_mask[60] = 1'b1;
                7'd69: corr_mask[61] = 1'b1;
                7'd70: corr_mask[62] = 1'b1;
                7'd71: corr_mask[63] = 1'b1;
                // Check-bit error positions (1,2,4,8,16,32,64) or cb[7] (synd=0):
                // data is already correct; corr_mask stays 0
                default: corr_mask = 64'h0;
            endcase
        end
    end

    // Apply correction mask to received data
    always @(*) begin
        dec_data_out = d_r ^ corr_mask;
    end

endmodule

`default_nettype wire
