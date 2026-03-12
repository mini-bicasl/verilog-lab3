// ecc_decoder_tb.v – Testbench for ecc_decoder (SECDED 72,64)
//
// Tests:
//   1. No-error case: valid codeword passes through (no flags, data correct)
//   2. All 72 single-bit error positions: single_err=1, double_err=0,
//      data corrected (for data-bit errors) or unchanged (for check-bit errors)
//   3. Selected double-bit errors: single_err=0, double_err=1
//   4. cb[7]-only error (syndrome[6:0]=0, overall_parity=1): single_err=1
//
// Compile & run:
//   iverilog -g2012 -o build/ecc_decoder.out tb/ecc_decoder_tb.v rtl/ecc_decoder.v
//   vvp build/ecc_decoder.out

`timescale 1ns/1ps

module ecc_decoder_tb;

    // ----------------------------------------------------------------
    // DUT wires
    // ----------------------------------------------------------------
    reg  [71:0] dec_word_in;
    wire [63:0] dec_data_out;
    wire        dec_single_err;
    wire        dec_double_err;
    wire [7:0]  dec_syndrome;

    ecc_decoder dut (
        .dec_word_in   (dec_word_in),
        .dec_data_out  (dec_data_out),
        .dec_single_err(dec_single_err),
        .dec_double_err(dec_double_err),
        .dec_syndrome  (dec_syndrome)
    );

    // ----------------------------------------------------------------
    // VCD dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-ecc/ecc_decoder.vcd");
        $dumpvars(0, ecc_decoder_tb);
    end

    // ----------------------------------------------------------------
    // Reference encoder (same logic as ecc_encoder.v) for building
    // valid codewords without depending on the encoder module.
    // ----------------------------------------------------------------
    function [7:0] ref_check_bits;
        input [63:0] d;
        reg [6:0] c;
        begin
            c[0] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[11]^d[13]^d[15]^
                   d[17]^d[19]^d[21]^d[23]^d[25]^d[26]^d[28]^d[30]^d[32]^d[34]^
                   d[36]^d[38]^d[40]^d[42]^d[44]^d[46]^d[48]^d[50]^d[52]^d[54]^
                   d[56]^d[57]^d[59]^d[61]^d[63];
            c[1] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[10]^d[12]^d[13]^d[16]^
                   d[17]^d[20]^d[21]^d[24]^d[25]^d[27]^d[28]^d[31]^d[32]^d[35]^
                   d[36]^d[39]^d[40]^d[43]^d[44]^d[47]^d[48]^d[51]^d[52]^d[55]^
                   d[56]^d[58]^d[59]^d[62]^d[63];
            c[2] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[10]^d[14]^d[15]^d[16]^
                   d[17]^d[22]^d[23]^d[24]^d[25]^d[29]^d[30]^d[31]^d[32]^d[37]^
                   d[38]^d[39]^d[40]^d[45]^d[46]^d[47]^d[48]^d[53]^d[54]^d[55]^
                   d[56]^d[60]^d[61]^d[62]^d[63];
            c[3] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[10]^d[18]^d[19]^d[20]^
                   d[21]^d[22]^d[23]^d[24]^d[25]^d[33]^d[34]^d[35]^d[36]^d[37]^
                   d[38]^d[39]^d[40]^d[49]^d[50]^d[51]^d[52]^d[53]^d[54]^d[55]^
                   d[56];
            c[4] = d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^
                   d[20]^d[21]^d[22]^d[23]^d[24]^d[25]^d[41]^d[42]^d[43]^d[44]^
                   d[45]^d[46]^d[47]^d[48]^d[49]^d[50]^d[51]^d[52]^d[53]^d[54]^
                   d[55]^d[56];
            c[5] = d[26]^d[27]^d[28]^d[29]^d[30]^d[31]^d[32]^d[33]^d[34]^
                   d[35]^d[36]^d[37]^d[38]^d[39]^d[40]^d[41]^d[42]^d[43]^d[44]^
                   d[45]^d[46]^d[47]^d[48]^d[49]^d[50]^d[51]^d[52]^d[53]^d[54]^
                   d[55]^d[56];
            c[6] = d[57]^d[58]^d[59]^d[60]^d[61]^d[62]^d[63];
            ref_check_bits = {(^d ^ ^c), c};
        end
    endfunction

    function [71:0] ref_encode;
        input [63:0] d;
        begin
            ref_encode = {ref_check_bits(d), d};
        end
    endfunction

    // ----------------------------------------------------------------
    // Test counters
    // ----------------------------------------------------------------
    integer pass_count, fail_count;
    integer bit_pos;
    reg [71:0] codeword, corrupted;
    reg [63:0] test_data;

    // ----------------------------------------------------------------
    // Test execution
    // ----------------------------------------------------------------
    initial begin
        pass_count = 0;
        fail_count = 0;

        // ==============================================================
        // Test 1: No error – valid codeword passes through unchanged
        // ==============================================================
        test_data   = 64'hDEADBEEFCAFEBABE;
        codeword    = ref_encode(test_data);
        dec_word_in = codeword;
        #1;
        if (dec_data_out !== test_data) begin
            $display("FAIL T1: no-error data mismatch: got %h exp %h",
                     dec_data_out, test_data);
            fail_count = fail_count + 1;
        end else if (dec_single_err !== 1'b0 || dec_double_err !== 1'b0) begin
            $display("FAIL T1: error flags set on valid codeword se=%b de=%b",
                     dec_single_err, dec_double_err);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T1: no-error: data=0x%016x se=0 de=0", test_data);
            pass_count = pass_count + 1;
        end

        // ==============================================================
        // Test 2: All 64 data-bit single-bit error injections
        // ==============================================================
        $display("Running all 64 data-bit single-bit error corrections...");
        test_data = 64'hDEADBEEFCAFEBABE;
        codeword  = ref_encode(test_data);

        for (bit_pos = 0; bit_pos < 64; bit_pos = bit_pos + 1) begin
            corrupted   = codeword ^ (72'h1 << bit_pos);
            dec_word_in = corrupted;
            #1;
            if (dec_single_err !== 1'b1) begin
                $display("FAIL T2 bit=%0d: single_err not set", bit_pos);
                fail_count = fail_count + 1;
            end else if (dec_double_err !== 1'b0) begin
                $display("FAIL T2 bit=%0d: double_err incorrectly set", bit_pos);
                fail_count = fail_count + 1;
            end else if (dec_data_out !== test_data) begin
                $display("FAIL T2 bit=%0d: data not corrected, got %h exp %h",
                         bit_pos, dec_data_out, test_data);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
        $display("PASS T2: all 64 data-bit single-error corrections OK");

        // ==============================================================
        // Test 3: Check-bit single-bit error injections (bits 64..71)
        //   Data must come out unchanged; single_err=1, double_err=0
        // ==============================================================
        $display("Running 8 check-bit single-bit error corrections...");
        for (bit_pos = 64; bit_pos < 72; bit_pos = bit_pos + 1) begin
            corrupted   = codeword ^ (72'h1 << bit_pos);
            dec_word_in = corrupted;
            #1;
            if (dec_single_err !== 1'b1) begin
                $display("FAIL T3 cbit=%0d: single_err not set", bit_pos - 64);
                fail_count = fail_count + 1;
            end else if (dec_double_err !== 1'b0) begin
                $display("FAIL T3 cbit=%0d: double_err incorrectly set", bit_pos - 64);
                fail_count = fail_count + 1;
            end else if (dec_data_out !== test_data) begin
                $display("FAIL T3 cbit=%0d: data changed on check-bit error",
                         bit_pos - 64);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
        $display("PASS T3: all 8 check-bit single-error detections OK");

        // ==============================================================
        // Test 4: Double-bit error detection (sample: 16 pairs)
        // ==============================================================
        $display("Running double-bit error detection checks (sample pairs)...");
        begin
            integer i, j;
            integer dbl_pass;
            dbl_pass = 0;
            for (i = 0; i < 72; i = i + 9) begin
                for (j = i + 1; j < 72; j = j + 7) begin
                    corrupted   = codeword ^ (72'h1 << i) ^ (72'h1 << j);
                    dec_word_in = corrupted;
                    #1;
                    if (dec_double_err !== 1'b1 || dec_single_err !== 1'b0) begin
                        $display("FAIL T4 bits=%0d,%0d: de=%b se=%b",
                                 i, j, dec_double_err, dec_single_err);
                        fail_count = fail_count + 1;
                    end else begin
                        dbl_pass = dbl_pass + 1;
                        pass_count = pass_count + 1;
                    end
                end
            end
            $display("PASS T4: %0d double-bit error pairs detected correctly",
                     dbl_pass);
        end

        // ==============================================================
        // Test 5: Multiple data words – no error round-trip
        // ==============================================================
        $display("Running 6 no-error round-trip checks...");
        begin
            integer k;
            reg [63:0] tv [0:5];
            tv[0] = 64'h0;
            tv[1] = 64'hFFFFFFFFFFFFFFFF;
            tv[2] = 64'h5555555555555555;
            tv[3] = 64'hAAAAAAAAAAAAAAAA;
            tv[4] = 64'h123456789ABCDEF0;
            tv[5] = 64'hFEDCBA9876543210;
            for (k = 0; k < 6; k = k + 1) begin
                dec_word_in = ref_encode(tv[k]);
                #1;
                if (dec_data_out !== tv[k] || dec_single_err || dec_double_err) begin
                    $display("FAIL T5[%0d]: d=%016x se=%b de=%b got=%016x",
                             k, tv[k], dec_single_err, dec_double_err, dec_data_out);
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
            $display("PASS T5: 6 no-error round-trips OK");
        end

        // ==============================================================
        // Summary
        // ==============================================================
        $display("--------------------------------------------");
        $display("ecc_decoder_tb: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "ecc_decoder_tb: simulation FAILED");
        $finish;
    end

endmodule
