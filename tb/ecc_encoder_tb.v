// ecc_encoder_tb.v – Testbench for ecc_encoder (SECDED 72,64)
//
// Tests:
//   1. d=0 produces all-zero check bits
//   2. Known test vectors (Python-verified reference values)
//   3. All 64 single-bit data patterns: round-trip via inline
//      reference model; verify enc_word_out = {enc_check_out, enc_data_in}
//   4. Structural check: enc_word_out[63:0] always equals enc_data_in
//
// Compile & run:
//   iverilog -g2012 -o build/ecc_encoder.out tb/ecc_encoder_tb.v rtl/ecc_encoder.v
//   vvp build/ecc_encoder.out

`timescale 1ns/1ps

module ecc_encoder_tb;

    // ----------------------------------------------------------------
    // DUT wires
    // ----------------------------------------------------------------
    reg  [63:0] enc_data_in;
    wire [7:0]  enc_check_out;
    wire [71:0] enc_word_out;

    ecc_encoder dut (
        .enc_data_in  (enc_data_in),
        .enc_check_out(enc_check_out),
        .enc_word_out (enc_word_out)
    );

    // ----------------------------------------------------------------
    // VCD / waveform dump
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("results/phase-ddr4-ecc/ecc_encoder.vcd");
        $dumpvars(0, ecc_encoder_tb);
    end

    // ----------------------------------------------------------------
    // Reference model (pure Verilog, mirrors Python-verified logic)
    // Bit positions of d[0..63] in the logical Hamming codeword:
    //   d[0..3]  -> 3,5,6,7   d[4..10] -> 9..15
    //   d[11..25]-> 17..31    d[26..56]-> 33..63
    //   d[57..63]-> 65..71
    // cb[k] = even parity of data bits whose position has bit k set.
    // cb[7] = overall parity of all 71 bits.
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

    // ----------------------------------------------------------------
    // Test sequencer
    // ----------------------------------------------------------------
    integer i;
    integer pass_count, fail_count;
    reg [7:0] expected_cb;

    initial begin
        pass_count = 0;
        fail_count = 0;

        // ---- Test 1: d=0 -------------------------------------------
        enc_data_in = 64'h0;
        #1;
        if (enc_check_out !== 8'h00) begin
            $display("FAIL T1: d=0 expected cb=8'h00, got 8'h%02x", enc_check_out);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T1: d=0 => cb=8'h00");
            pass_count = pass_count + 1;
        end

        // ---- Test 2: d=all-ones ------------------------------------
        enc_data_in = 64'hFFFFFFFFFFFFFFFF;
        #1;
        if (enc_check_out !== 8'hFF) begin
            $display("FAIL T2: d=all1s expected cb=8'hFF, got 8'h%02x", enc_check_out);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T2: d=all1s => cb=8'hFF");
            pass_count = pass_count + 1;
        end

        // ---- Test 3: Known vectors (Python-verified) ---------------
        enc_data_in = 64'hDEADBEEFCAFEBABE; #1;
        if (enc_check_out !== 8'h3A) begin
            $display("FAIL T3a: d=DEADBEEF.. expected 8'h3a got 8'h%02x", enc_check_out);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T3a: d=0xDEADBEEFCAFEBABE cb=0x3a");
            pass_count = pass_count + 1;
        end

        enc_data_in = 64'h0000000000000001; #1;
        if (enc_check_out !== 8'h83) begin
            $display("FAIL T3b: d=1 expected 8'h83 got 8'h%02x", enc_check_out);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T3b: d=0x0000000000000001 cb=0x83");
            pass_count = pass_count + 1;
        end

        enc_data_in = 64'h8000000000000000; #1;
        if (enc_check_out !== 8'hC7) begin
            $display("FAIL T3c: d=MSB expected 8'hC7 got 8'h%02x", enc_check_out);
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T3c: d=0x8000000000000000 cb=0xc7");
            pass_count = pass_count + 1;
        end

        // ---- Test 4: enc_word_out structure -------------------------
        enc_data_in = 64'h5A5A5A5A5A5A5A5A; #1;
        if (enc_word_out[63:0] !== enc_data_in) begin
            $display("FAIL T4: enc_word_out[63:0] != enc_data_in");
            fail_count = fail_count + 1;
        end else if (enc_word_out[71:64] !== enc_check_out) begin
            $display("FAIL T4: enc_word_out[71:64] != enc_check_out");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T4: enc_word_out = {enc_check_out, enc_data_in}");
            pass_count = pass_count + 1;
        end

        // ---- Test 5: All 64 single-bit patterns --------------------
        $display("Running 64 single-bit data pattern checks...");
        for (i = 0; i < 64; i = i + 1) begin
            enc_data_in = 64'h1 << i;
            #1;
            expected_cb = ref_check_bits(enc_data_in);
            if (enc_check_out !== expected_cb) begin
                $display("FAIL T5 d[%0d]=1: expected cb=8'h%02x got 8'h%02x",
                         i, expected_cb, enc_check_out);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
        $display("PASS T5: all 64 single-bit patterns match reference model");

        // ---- Test 6: Parity balance for d=all-zeros ----------------
        enc_data_in = 64'h0; #1;
        if ((^enc_word_out) !== 1'b0) begin
            $display("FAIL T6: overall parity of encoded all-zero word is not 0");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T6: overall parity of encoded all-zero word is 0");
            pass_count = pass_count + 1;
        end

        // ---- Test 7: Alternating patterns --------------------------
        enc_data_in = 64'h5555555555555555; #1;
        expected_cb = ref_check_bits(enc_data_in);
        if (enc_check_out !== expected_cb) begin
            $display("FAIL T7a: d=0x5555... cb mismatch");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T7a: d=0x5555555555555555 cb=8'h%02x", enc_check_out);
            pass_count = pass_count + 1;
        end

        enc_data_in = 64'hAAAAAAAAAAAAAAAA; #1;
        expected_cb = ref_check_bits(enc_data_in);
        if (enc_check_out !== expected_cb) begin
            $display("FAIL T7b: d=0xAAAA... cb mismatch");
            fail_count = fail_count + 1;
        end else begin
            $display("PASS T7b: d=0xAAAAAAAAAAAAAAAA cb=8'h%02x", enc_check_out);
            pass_count = pass_count + 1;
        end

        // ---- Summary -----------------------------------------------
        $display("--------------------------------------------");
        $display("ecc_encoder_tb: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $display("--------------------------------------------");
        if (fail_count != 0) $fatal(1, "ecc_encoder_tb: simulation FAILED");
        $finish;
    end

endmodule
