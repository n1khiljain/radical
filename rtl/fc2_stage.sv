// =============================================================================
// fc2_stage.sv
// Fully-connected layer 2 (output layer): IN_SIZE inputs -> OUT_SIZE outputs
// No ReLU -- raw logit scores fed to argmax classification.
//
// =============================================================================
// DATA FLOW
// =============================================================================
//
//   For each output neuron o (0 .. OUT_SIZE-1):
//     dot_acc[o]   = sum_{i} act_in[i] * weights[o][i]    (64-bit accumulator)
//     post_bias[o] = dot_acc[o] + sign_extend(bias[o])    (64-bit)
//     act_out[o]   = post_bias[o][31:0]                   (32-bit, no ReLU)
//
//   Negative scores are preserved (no clamping).
//
// Default parameters match the real FC2 shape:
//   IN_SIZE=32 (fc1 output), OUT_SIZE=10 (digit classes 0-9)
//
// =============================================================================
// COMPILE PERFORMANCE NOTE
// =============================================================================
//
//   Uses the same per-neuron generate-loop structure as fc1_stage so that
//   each always_comb block covers only IN_SIZE MACs (not OUT_SIZE * IN_SIZE).
//   dot_acc[] and post_bias[] are kept as module-level nets (driven via
//   continuous assignment) so testbench hierarchical references still work.
//
// =============================================================================

module fc2_stage #(
    parameter int IN_SIZE  = 32,
    parameter int OUT_SIZE = 10
) (
    input  logic signed [31:0] act_in  [0:IN_SIZE-1],
    input  logic signed [7:0]  weights [0:OUT_SIZE-1][0:IN_SIZE-1],
    input  logic signed [31:0] bias    [0:OUT_SIZE-1],
    output logic signed [31:0] act_out [0:OUT_SIZE-1]
);

    // =========================================================================
    // Module-level arrays (accessible via hierarchical path from testbenches)
    // Each element is driven by a continuous assignment from generate scope.
    // =========================================================================
    logic signed [63:0] dot_acc   [0:OUT_SIZE-1];   // raw dot products (pre-bias)
    logic signed [63:0] post_bias [0:OUT_SIZE-1];   // post-bias scores

    // =========================================================================
    // Per-neuron generate blocks
    //
    // Each g_neuron[o] instance owns:
    //   dot_g  -- 64-bit private accumulator for neuron o
    // And drives (via continuous assignment):
    //   dot_acc[o], post_bias[o], act_out[o]
    //
    // fc2 differs from fc1 only in Step 3: no ReLU clamp, plain truncation.
    // =========================================================================
    generate
        for (genvar o = 0; o < OUT_SIZE; o++) begin : g_neuron

            logic signed [63:0] dot_g;  // private accumulator for this neuron

            // -----------------------------------------------------------------
            // Dot product: sum act_in[i] * weights[o][i]
            // Both operands are sign-extended to 64 bits before multiplication.
            // -----------------------------------------------------------------
            always_comb begin
                dot_g = 64'sh0;
                for (int i = 0; i < IN_SIZE; i++)
                    dot_g = dot_g + 64'(signed'(act_in[i])) *
                                    64'(signed'(weights[o][i]));
            end

            // -----------------------------------------------------------------
            // Bias addition and 32-bit truncation (NO ReLU).
            // Negative logit scores are preserved in two's complement.
            // -----------------------------------------------------------------
            assign dot_acc[o]   = dot_g;
            assign post_bias[o] = dot_g + 64'(signed'(bias[o]));
            assign act_out[o]   = post_bias[o][31:0];

        end
    endgenerate

endmodule : fc2_stage
