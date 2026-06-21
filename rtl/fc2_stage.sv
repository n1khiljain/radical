// =============================================================================
// fc2_stage.sv
// Fully-connected layer 2 (output layer): IN_SIZE inputs → OUT_SIZE outputs
// No ReLU — raw logit scores fed to argmax classification.
//
// =============================================================================
// DATA FLOW
// =============================================================================
//
//   For each output neuron o (0 .. OUT_SIZE-1):
//     dot_acc[o]  = Σ_{i=0}^{IN_SIZE-1}  act_in[i] × weights[o][i]  (64-bit)
//     post_bias[o] = dot_acc[o] + sign_extend(bias[o])               (64-bit)
//     act_out[o]  = post_bias[o][31:0]                               (32-bit)
//
//   Negative scores are preserved (no clamping).
//
// Default parameters match the real FC2 shape:
//   IN_SIZE=32 (fc1 output), OUT_SIZE=10 (digit classes 0-9)
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
    // Internal arrays (accessible from testbench via hierarchical reference)
    // =========================================================================

    // 64-bit dot-product results (pre-bias)
    logic signed [63:0] dot_acc   [0:OUT_SIZE-1];

    // 64-bit post-bias values (final score before truncation)
    logic signed [63:0] post_bias [0:OUT_SIZE-1];

    // Shared temporaries — sequentially valid inside always_comb
    logic signed [63:0] in64, wt64, acc_tmp, bias64;

    // =========================================================================
    // Step 1 — Dot product: Σ act_in[i] × weights[o][i]
    // =========================================================================
    always_comb begin
        for (int o = 0; o < OUT_SIZE; o++) begin
            acc_tmp = 64'sh0;
            for (int i = 0; i < IN_SIZE; i++) begin
                in64    = act_in[i];       // 32-bit signed → 64-bit (sign-extend)
                wt64    = weights[o][i];   //  8-bit signed → 64-bit (sign-extend)
                acc_tmp = acc_tmp + in64 * wt64;
            end
            dot_acc[o] = acc_tmp;
        end
    end

    // =========================================================================
    // Step 2 — Bias addition
    // =========================================================================
    always_comb begin
        for (int o = 0; o < OUT_SIZE; o++) begin
            bias64       = bias[o];         // 32-bit signed → 64-bit (sign-extend)
            post_bias[o] = dot_acc[o] + bias64;
        end
    end

    // =========================================================================
    // Step 3 — Truncate to 32-bit output (NO ReLU — negative scores preserved)
    //
    //   Negative values: lower 32 bits of a negative 64-bit value are the
    //   correct 32-bit two's-complement representation when the value fits
    //   in [-2^31, 2^31-1], which the architecture guarantees for FC2 scores.
    // =========================================================================
    always_comb begin
        for (int o = 0; o < OUT_SIZE; o++) begin
            act_out[o] = post_bias[o][31:0];
        end
    end

endmodule : fc2_stage
