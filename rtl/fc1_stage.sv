// =============================================================================
// fc1_stage.sv
// Fully-connected layer 1: IN_SIZE inputs → OUT_SIZE outputs + ReLU
//
// =============================================================================
// DATA FLOW
// =============================================================================
//
//   For each output neuron o (0 .. OUT_SIZE-1):
//     dot_acc[o] = Σ_{i=0}^{IN_SIZE-1}  act_in[i] × weights[o][i]   (64-bit)
//     pre_relu[o] = dot_acc[o] + sign_extend(bias[o])                (64-bit)
//     act_out[o]  = max(0, pre_relu[o])[31:0]                        (32-bit)
//
// =============================================================================
// SIZING RATIONALE
// =============================================================================
//
//   act_in:  32-bit signed (carried from conv2 without requantization)
//   weights: INT8 signed
//   bias:    32-bit signed
//
//   Per-product worst case:
//     act_in ≤ 2^31  ×  weight ≤ 127 = ~2^38  →  needs 39 bits + sign
//   Accumulated over IN_SIZE=784 products:
//     784 × 2^38 ≈ 2^48  →  needs 49 bits + sign
//   → 64-bit signed accumulator is sufficient with ample margin.
//
//   Output truncated to 32-bit after ReLU.  The bias add is performed at
//   64-bit precision before truncation.
//
// Default parameters match the real FC1 shape (flattened conv2 output = 16×7×7):
//   IN_SIZE=784, OUT_SIZE=32
// =============================================================================

module fc1_stage #(
    parameter int IN_SIZE  = 784,
    parameter int OUT_SIZE = 32
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
    logic signed [63:0] dot_acc  [0:OUT_SIZE-1];

    // 64-bit post-bias values (input to ReLU)
    logic signed [63:0] pre_relu [0:OUT_SIZE-1];

    // Shared temporaries — sequentially valid inside always_comb
    logic signed [63:0] in64, wt64, acc_tmp, bias64;

    // =========================================================================
    // Step 1 — Dot product: Σ act_in[i] × weights[o][i]
    //
    //   in64 = sign_extend(act_in[i],  32→64)  [automatic signed assignment]
    //   wt64 = sign_extend(weights[o][i], 8→64) [automatic signed assignment]
    //   Product: in64 × wt64 → 64-bit (safe: max 2^38 << 2^63)
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
    // Step 2 — Bias addition (32-bit bias sign-extended to 64 bits)
    // =========================================================================
    always_comb begin
        for (int o = 0; o < OUT_SIZE; o++) begin
            bias64      = bias[o];          // 32-bit signed → 64-bit (sign-extend)
            pre_relu[o] = dot_acc[o] + bias64;
        end
    end

    // =========================================================================
    // Step 3 — ReLU + truncate to 32-bit output
    //
    //   Sign bit [63] of the 64-bit accumulator determines the clamp.
    //   Non-negative values are truncated to [31:0]; the architecture guarantees
    //   these fit in 32-bit signed after FC1.
    // =========================================================================
    always_comb begin
        for (int o = 0; o < OUT_SIZE; o++) begin
            act_out[o] = pre_relu[o][63] ? 32'sh0 : pre_relu[o][31:0];
        end
    end

endmodule : fc1_stage
