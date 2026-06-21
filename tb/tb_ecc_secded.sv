// =============================================================================
// tb_ecc_secded.sv
// Testbench for ecc_secded — SECDED Hamming codec
//
// =============================================================================
// HAND-DERIVED EXAMPLE  (data_in = 8'hAC = 8'b1010_1100)
// =============================================================================
//
//  Data bit assignment (data_in[0]=D1 .. data_in[7]=D8):
//    D1=0, D2=0, D3=1, D4=1, D5=0, D6=1, D7=0, D8=1
//
//  Hamming parity (standard coverage):
//    P1 = D1^D2^D4^D5^D7 = 0^0^1^0^0 = 1
//    P2 = D1^D3^D4^D6^D7 = 0^1^1^1^0 = 1
//    P4 = D2^D3^D4^D8    = 0^1^1^1   = 1
//    P8 = D5^D6^D7^D8    = 0^1^0^1   = 0
//
//  Bits at positions 1-12:
//    P1=1, P2=1, D1=0, P4=1, D2=0, D3=1, D4=1, P8=0, D5=0, D6=1, D7=0, D8=1
//    Count = 7 ones (odd) → P_all = 1
//
//  Codeword assembly (codeword[k-1] = position k):
//    bit12=P_all=1, bit11=D8=1, bit10=D7=0, bit9=D6=1, bit8=D5=0,
//    bit7=P8=0,     bit6=D4=1,  bit5=D3=1,  bit4=D2=0, bit3=P4=1,
//    bit2=D1=0,     bit1=P2=1,  bit0=P1=1
//    codeword_out = 13'b1_1_0_1_0_0_1_1_0_1_0_1_1 = 13'h1A6B
//
//  Single-bit error example — inject at position 6 (D3, bit5):
//    Corrupted  = 13'h1A6B ^ (1<<5) = 13'h1A4B   [D3 flipped 1→0]
//    P1_chk = 0^0^1^0^0 = 1,  S1 = 1^1 = 0   (pos 6 has bit0=0 → P1 not affected)
//    P2_chk = 0^0^1^1^0 = 0,  S2 = 0^1 = 1   (pos 6 has bit1=1 → P2 affected ✓)
//    P4_chk = 0^0^1^1   = 0,  S4 = 0^1 = 1   (pos 6 has bit2=1 → P4 affected ✓)
//    P8_chk = 0^1^0^1   = 0,  S8 = 0^0 = 0   (pos 6 has bit3=0 → P8 not affected)
//    Syndrome = {S8,S4,S2,S1} = {0,1,1,0} = 6 → error at position 6 ✓
//    overall_error = 1 (one bit flipped) → single-bit correctable ✓
//
// =============================================================================
// TEST PLAN
// =============================================================================
//  TC01 : No error    — clean codeword → status=00, data_corrected=8'hAC
//  TC02-TC14: Single-bit error at each of the 13 positions individually
//             Positions 1-12 → status=01 (corrected), data_corrected=8'hAC
//             Position  13   → status=00 (P_all-only), data_corrected=8'hAC
//  TC15 : Double-bit error (positions 1 and 2) → status=10 (uncorrectable)
// =============================================================================

module tb_ecc_secded;

    // -------------------------------------------------------------------------
    // DUT connections
    // -------------------------------------------------------------------------
    logic [7:0]  data_in;
    logic [12:0] codeword_out;
    logic [12:0] codeword_in;
    logic [7:0]  data_corrected;
    logic [1:0]  error_status;

    ecc_secded dut (
        .data_in       (data_in),
        .codeword_out  (codeword_out),
        .codeword_in   (codeword_in),
        .data_corrected(data_corrected),
        .error_status  (error_status)
    );

    // -------------------------------------------------------------------------
    // Test infrastructure
    // -------------------------------------------------------------------------
    integer fail_count;

    // Check task — combinational DUT so just read outputs after #1 propagation
    task automatic check (
        input string   test_id,
        input [7:0]    exp_data,
        input [1:0]    exp_status
    );
        if (data_corrected !== exp_data || error_status !== exp_status) begin
            $display("LOG: %0t : ERROR : tb_ecc_secded : %s : data exp=%0h got=%0h  status exp=%02b got=%02b",
                     $time, test_id, exp_data, data_corrected, exp_status, error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_ecc_secded : %s : data=%0h  status=%02b  OK",
                     $time, test_id, data_corrected, error_status);
        end
    endtask

    // -------------------------------------------------------------------------
    // Known-good constants derived from hand computation above
    // -------------------------------------------------------------------------
    localparam logic [7:0]  TEST_DATA  = 8'hAC;
    localparam logic [12:0] CLEAN_CW   = 13'h1A6B;  // hand-derived above

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("TEST START");
        fail_count  = 0;

        data_in    = TEST_DATA;
        codeword_in = CLEAN_CW;
        #1;

        // ------------------------------------------------------------------
        // Sanity check: encoder output matches hand-computed codeword
        // ------------------------------------------------------------------
        if (codeword_out !== CLEAN_CW) begin
            $display("LOG: %0t : ERROR : tb_ecc_secded : ENCODE : expected %0h  got %0h",
                     $time, CLEAN_CW, codeword_out);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_ecc_secded : ENCODE : codeword_out=%0h  OK",
                     $time, codeword_out);
        end

        // ------------------------------------------------------------------
        // TC01 — No error
        // ------------------------------------------------------------------
        codeword_in = CLEAN_CW;
        #1;
        check("TC01_no_error", TEST_DATA, 2'b00);

        // ------------------------------------------------------------------
        // TC02-TC14 — Single-bit error at each of the 13 codeword positions
        // ------------------------------------------------------------------
        $display("--- Single-bit error sweep ---");
        for (int pos = 1; pos <= 13; pos++) begin
            automatic logic [12:0] corrupted;
            automatic string       tc_name;
            automatic logic [1:0]  exp_stat;

            corrupted = CLEAN_CW ^ (13'd1 << (pos - 1));
            tc_name   = $sformatf("TC%02d_sbe_pos%02d", pos + 1, pos);
            // Position 13 is P_all — data bits intact, status=no_error
            exp_stat  = (pos == 13) ? 2'b00 : 2'b01;

            codeword_in = corrupted;
            #1;
            check(tc_name, TEST_DATA, exp_stat);
        end

        // ------------------------------------------------------------------
        // TC15 — Double-bit error (positions 1 and 2, bits 0 and 1)
        //   Corrupted = 13'h1A6B ^ 13'h0003 = 13'h1A68
        //   Two flipped bits → even parity change → overall_error=0
        //   Syndrome will be non-zero → detected as double-bit (status=10)
        //   data_corrected is NOT corrected (we don't assert what it is,
        //   only that error_status signals the uncorrectable condition)
        // ------------------------------------------------------------------
        $display("--- Double-bit error test ---");
        codeword_in = CLEAN_CW ^ 13'h0003;  // flip positions 1 and 2
        #1;
        if (error_status !== 2'b10) begin
            $display("LOG: %0t : ERROR : tb_ecc_secded : TC15_dbe : expected status=10 got=%02b",
                     $time, error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_ecc_secded : TC15_dbe : status=%02b (uncorrectable)  OK",
                     $time, error_status);
        end

        // ------------------------------------------------------------------
        // Additional double-bit error: positions 3 and 7 (a data-bit pair)
        // ------------------------------------------------------------------
        codeword_in = CLEAN_CW ^ (13'd1 << 2) ^ (13'd1 << 6);  // pos3, pos7
        #1;
        if (error_status !== 2'b10) begin
            $display("LOG: %0t : ERROR : tb_ecc_secded : TC16_dbe_pos3_7 : expected status=10 got=%02b",
                     $time, error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_ecc_secded : TC16_dbe_pos3_7 : status=%02b (uncorrectable)  OK",
                     $time, error_status);
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("ecc_secded testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("ecc_secded.fst");
        $dumpvars(0);
    end

endmodule : tb_ecc_secded
