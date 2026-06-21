// =============================================================================
// tb_mac_array.sv
// Testbench for mac_array — 8x8 INT8 systolic MAC array
//
// Test stimulus (hand-computed):
//
//   Weight matrix W (all-ones, 8x8):
//     W[i][j] = 1  for all i, j  (signed INT8)
//
//   Activation vector A:
//     A = [1, 2, 3, 4, 5, 6, 7, 8]  (signed INT8)
//
//   Expected result for every output row i:
//     result[i] = SUM_{j=0}^{7} W[i][j] * A[j]
//               = 1*1 + 1*2 + 1*3 + 1*4 + 1*5 + 1*6 + 1*7 + 1*8
//               = 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8
//               = 36   (for all 8 rows)
//
// Sequence:
//   Cycle 1 : reset=1  -> verify outputs are all zero
//   Cycle 2 : reset=0, weights & activations applied -> results captured
//   Post-clk: check results[0..7] == 36
// =============================================================================

module tb_mac_array;

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;
    logic signed [7:0]      weights     [0:7][0:7];
    logic signed [7:0]      activations [0:7];
    logic signed [18:0]     results     [0:7];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    mac_array dut (
        .clock       (clock),
        .reset       (reset),
        .weights     (weights),
        .activations (activations),
        .results     (results)
    );

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #500;
        $fatal(1, "TIMEOUT: simulation exceeded safety limit — check testbench logic");
    end

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    integer fail_count;
    logic signed [18:0] expected [0:7];

    initial begin
        $display("TEST START");

        fail_count = 0;

        // ------------------------------------------------------------------
        // Initialise all inputs before first clock edge
        // ------------------------------------------------------------------
        reset = 1'b1;

        // Weight matrix: all-ones (W[i][j] = +1 for all i, j)
        for (int i = 0; i < 8; i++) begin
            for (int j = 0; j < 8; j++) begin
                weights[i][j] = 8'sd1;
            end
        end

        // Activation vector: A = [1, 2, 3, 4, 5, 6, 7, 8]
        for (int k = 0; k < 8; k++) begin
            activations[k] = 8'(signed'(k + 1));
        end

        // ------------------------------------------------------------------
        // TEST 1 — Reset check
        // Apply reset for one full cycle; outputs must be zero
        // ------------------------------------------------------------------
        @(posedge clock); #1;   // Cycle 1 posedge: results <= 0 (reset active)

        for (int i = 0; i < 8; i++) begin
            if (results[i] !== 19'sd0) begin
                $display("LOG: %0t : ERROR : tb_mac_array : dut.results[%0d] : expected_value: 0 actual_value: %0d",
                         $time, i, results[i]);
                fail_count++;
            end else begin
                $display("LOG: %0t : INFO : tb_mac_array : dut.results[%0d] : expected_value: 0 actual_value: %0d",
                         $time, i, results[i]);
            end
        end

        // ------------------------------------------------------------------
        // TEST 2 — Single MAC pass
        // Deassert reset; weights and activations remain applied.
        // The combinational acc_comb is immediately valid; it will be
        // registered on the next rising clock edge.
        // ------------------------------------------------------------------
        reset = 1'b0;

        @(posedge clock); #1;   // Cycle 2 posedge: results <= acc_comb

        // Hand-computed expected value for every row:
        //   sum(1..8) = 1+2+3+4+5+6+7+8 = 36
        for (int i = 0; i < 8; i++) begin
            expected[i] = 19'sd36;
        end

        $display("--- MAC pass result check ---");
        for (int i = 0; i < 8; i++) begin
            if (results[i] !== expected[i]) begin
                $display("LOG: %0t : ERROR : tb_mac_array : dut.results[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i, expected[i], results[i]);
                fail_count++;
            end else begin
                $display("LOG: %0t : INFO : tb_mac_array : dut.results[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i, expected[i], results[i]);
            end
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("mac_array testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated due to output mismatch(es)");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("mac_array.fst");
        $dumpvars(0);
    end

endmodule : tb_mac_array
