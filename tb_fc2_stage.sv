// =============================================================================
// tb_fc2_stage.sv
// Testbench for fc2_stage — dot product, bias add, NO ReLU
//
// =============================================================================
// TEST CASE  (IN_SIZE=3, OUT_SIZE=2)
// =============================================================================
//
//   act_in = [1, 2, 3]
//
//   weights[0] = [+2,  0, -1]
//   weights[1] = [+1, +2, +3]
//
//   bias[0] = -20
//   bias[1] = -5
//
// =============================================================================
// HAND-DERIVED EXPECTED VALUES
// =============================================================================
//
//   Neuron 0:
//     dot = 1×(+2) + 2×(0) + 3×(-1) = 2+0-3 = -1
//     post_bias = -1 + (-20) = -21
//     act_out[0] = -21   (NO ReLU — negative score preserved as raw logit)
//
//   Neuron 1:
//     dot = 1×(+1) + 2×(+2) + 3×(+3) = 1+4+9 = 14
//     post_bias = 14 + (-5) = 9
//     act_out[1] = 9
//
//   Key property verified: fc2 does NOT clamp negative scores.
//   act_out[0]=-21 confirms the absence of ReLU (contrast with fc1_stage
//   where the same value would produce 0).
//
// =============================================================================
// VERIFICATION PHASES
// =============================================================================
//  Phase 1 : dot_acc[]   — 2 checks  (raw dot product before bias)
//  Phase 2 : post_bias[] — 2 checks  (post-bias 64-bit value)
//  Phase 3 : act_out[]   — 2 checks  (32-bit truncation, no ReLU)
// =============================================================================

module tb_fc2_stage;

    // -------------------------------------------------------------------------
    // Test parameters
    // -------------------------------------------------------------------------
    localparam int TB_IN  = 3;
    localparam int TB_OUT = 2;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic signed [31:0] act_in  [0:TB_IN-1];
    logic signed [7:0]  weights [0:TB_OUT-1][0:TB_IN-1];
    logic signed [31:0] bias    [0:TB_OUT-1];
    logic signed [31:0] act_out [0:TB_OUT-1];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    fc2_stage #(
        .IN_SIZE (TB_IN),
        .OUT_SIZE(TB_OUT)
    ) dut (
        .act_in (act_in),
        .weights(weights),
        .bias   (bias),
        .act_out(act_out)
    );

    integer fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Apply stimulus
        // ------------------------------------------------------------------

        // act_in = [1, 2, 3]
        act_in[0] = 32'sd1;
        act_in[1] = 32'sd2;
        act_in[2] = 32'sd3;

        // weights[0] = [+2, 0, -1]
        weights[0][0] = 8'sd2;
        weights[0][1] = 8'sd0;
        weights[0][2] = 8'shFF;   // -1

        // weights[1] = [+1, +2, +3]
        weights[1][0] = 8'sd1;
        weights[1][1] = 8'sd2;
        weights[1][2] = 8'sd3;

        // bias[0] = -20,  bias[1] = -5
        bias[0] = -32'sd20;
        bias[1] = -32'sd5;

        #1;   // Allow combinational logic to settle

        // ==================================================================
        // Phase 1 — dot_acc: raw dot products (before bias)
        //   dot_acc[0] = 1×2 + 2×0 + 3×(-1) = 2+0-3 = -1
        //   dot_acc[1] = 1×1 + 2×2 + 3×3    = 1+4+9 = 14
        // ==================================================================
        $display("--- Phase 1: dot_acc (raw dot products) ---");

        if (dut.dot_acc[0] !== -64'sd1) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : dot_acc[0] : expected=-1 actual=%0d",
                     $time, dut.dot_acc[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : dot_acc[0]=-1  OK", $time);

        if (dut.dot_acc[1] !== 64'sd14) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : dot_acc[1] : expected=14 actual=%0d",
                     $time, dut.dot_acc[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : dot_acc[1]=14  OK", $time);

        // ==================================================================
        // Phase 2 — post_bias: post-bias 64-bit scores
        //   post_bias[0] = -1 + (-20) = -21
        //   post_bias[1] = 14 + (-5)  =   9
        // ==================================================================
        $display("--- Phase 2: post_bias (post-bias 64-bit scores) ---");

        if (dut.post_bias[0] !== -64'sd21) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : post_bias[0] : expected=-21 actual=%0d",
                     $time, dut.post_bias[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : post_bias[0]=-21  OK", $time);

        if (dut.post_bias[1] !== 64'sd9) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : post_bias[1] : expected=9 actual=%0d",
                     $time, dut.post_bias[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : post_bias[1]=9  OK", $time);

        // ==================================================================
        // Phase 3 — act_out: 32-bit truncation, NO ReLU
        //   act_out[0] = -21   (negative score preserved — no clamping)
        //   act_out[1] =   9
        // ==================================================================
        $display("--- Phase 3: act_out (32-bit output, no ReLU) ---");

        if (act_out[0] !== -32'sd21) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : act_out[0] : expected=-21 actual=%0d",
                     $time, act_out[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : act_out[0]=-21 (negative logit preserved)  OK",
                     $time);

        if (act_out[1] !== 32'sd9) begin
            $display("LOG: %0t : ERROR : tb_fc2_stage : act_out[1] : expected=9 actual=%0d",
                     $time, act_out[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc2_stage : act_out[1]=9  OK", $time);

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("fc2_stage: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("fc2_stage.fst");
        $dumpvars(0);
    end

endmodule : tb_fc2_stage
