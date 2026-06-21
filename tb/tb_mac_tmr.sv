// =============================================================================
// tb_mac_tmr.sv
// Unit testbench for mac_tmr.sv
//
// =============================================================================
// TEST STRATEGY
// =============================================================================
//
//   All three cases use the same small weight/activation values so results
//   can be verified by hand.
//
//   Test weights (same for all lanes):
//     weights[i][j] = 1 for all i,j  (identity-like)
//
//   Test activations:
//     activations[j] = j+1  -> [1,2,3,4,5,6,7,8]
//
//   Expected dot product for each lane:
//     result[i] = sum_{j=0}^{7} 1 * (j+1) = 1+2+3+4+5+6+7+8 = 36
//
//   Case 1 -- HARDENING_EN=1, all three instances agree:
//     voted result[i] = 36, disagreement = 0
//
//   Case 2 -- HARDENING_EN=1, one instance forced to corrupt output
//     (via hierarchical override of u_mac_a.results):
//     voted result[i] = 36 (B and C still agree), disagreement = 1
//
//   Case 3 -- HARDENING_EN=0 passthrough:
//     Instantiate a separate DUT with HARDENING_EN=0.
//     result[i] = 36, disagreement = 0
//
// =============================================================================

module tb_mac_tmr;

    // -------------------------------------------------------------------------
    // Shared stimulus
    // -------------------------------------------------------------------------
    logic        clock, reset;
    logic signed [7:0]  weights     [0:7][0:7];
    logic signed [7:0]  activations [0:7];

    // -------------------------------------------------------------------------
    // DUT A: HARDENING_EN=1 (TMR active)
    // -------------------------------------------------------------------------
    logic signed [18:0] results_tmr [0:7];
    logic               disagree_tmr;

    mac_tmr #(.HARDENING_EN(1)) dut_tmr (
        .clock       (clock),
        .reset       (reset),
        .weights     (weights),
        .activations (activations),
        .results     (results_tmr),
        .disagreement(disagree_tmr)
    );

    // -------------------------------------------------------------------------
    // DUT B: HARDENING_EN=0 (passthrough)
    // -------------------------------------------------------------------------
    logic signed [18:0] results_pass [0:7];
    logic               disagree_pass;

    mac_tmr #(.HARDENING_EN(0)) dut_pass (
        .clock       (clock),
        .reset       (reset),
        .weights     (weights),
        .activations (activations),
        .results     (results_pass),
        .disagreement(disagree_pass)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clock = 0;
    always  #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    integer fail_count;
    localparam int EXPECTED_DOT = 36; // 1+2+3+4+5+6+7+8

    task automatic chk_lane(
        input logic signed [18:0] actual,
        input int                 expected,
        input int                 lane,
        input string              ctx
    );
        if (signed'(actual) !== 19'(signed'(expected))) begin
            $display("LOG: %0t : ERROR : tb_mac_tmr : %s lane[%0d] exp=%0d got=%0d",
                     $time, ctx, lane, expected, signed'(actual));
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_mac_tmr : %s lane[%0d] = %0d  OK",
                     $time, ctx, lane, signed'(actual));
    endtask

    task automatic chk1(
        input int    actual,
        input int    expected,
        input string msg
    );
        if (actual !== expected) begin
            $display("LOG: %0t : ERROR : tb_mac_tmr : %s exp=%0d got=%0d",
                     $time, msg, expected, actual);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_mac_tmr : %s = %0d  OK",
                     $time, msg, actual);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // Initialize stimulus
        reset = 1'b1;
        for (int i = 0; i < 8; i++) begin
            for (int j = 0; j < 8; j++)
                weights[i][j] = 8'sd1;
            activations[i] = signed'(8'(i + 1));  // 1,2,...,8
        end

        // Release reset after 2 cycles
        repeat(2) @(posedge clock);
        #1; reset = 1'b0;

        // Wait 1 cycle for mac_array output registers to capture
        @(posedge clock); #1;

        // ==================================================================
        // Case 1: TMR, all copies agree
        // ==================================================================
        $display("--- Case 1: HARDENING_EN=1, all agree ---");
        for (int i = 0; i < 8; i++)
            chk_lane(results_tmr[i], EXPECTED_DOT, i, "TMR_all_agree");
        chk1(int'(disagree_tmr), 0, "disagree_tmr_all_agree");

        // ==================================================================
        // Case 2: TMR, copy A corrupted via hierarchical override
        // Force all lanes of u_mac_a.results to 0 (wrong value).
        // B and C still output 36, so voted result should still be 36
        // and disagreement should fire.
        // ==================================================================
        $display("--- Case 2: HARDENING_EN=1, copy A corrupted ---");
        for (int i = 0; i < 8; i++)
            force dut_tmr.g_tmr.u_mac_a.results[i] = 19'sd0;

        #1;  // combinational voter re-evaluates after force

        for (int i = 0; i < 8; i++)
            chk_lane(results_tmr[i], EXPECTED_DOT, i, "TMR_A_corrupt_voted");
        chk1(int'(disagree_tmr), 1, "disagree_tmr_A_corrupt");

        // Release the forced override
        for (int i = 0; i < 8; i++)
            release dut_tmr.g_tmr.u_mac_a.results[i];

        // ==================================================================
        // Case 3: HARDENING_EN=0, passthrough
        // ==================================================================
        $display("--- Case 3: HARDENING_EN=0 passthrough ---");
        #1;
        for (int i = 0; i < 8; i++)
            chk_lane(results_pass[i], EXPECTED_DOT, i, "passthrough");
        chk1(int'(disagree_pass), 0, "disagree_passthrough");

        // ==================================================================
        // Final verdict
        // ==================================================================
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("mac_tmr: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end
        $finish;
    end

    initial begin
        $dumpfile("mac_tmr.fst");
        $dumpvars(0);
    end

endmodule : tb_mac_tmr
