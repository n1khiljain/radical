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
// VERILATOR COMPILE-TIME NOTE
// =============================================================================
//
//   A single always_comb with OUT_SIZE × IN_SIZE MACs (e.g. 32×784 = 25,088)
//   causes Verilator to generate one massive C++ function that takes minutes
//   to compile.  The solution is to use a generate loop — one always_comb per
//   output neuron — so Verilator emits OUT_SIZE small functions instead.
//
//   dot_acc[] and pre_relu[] are kept as module-level nets (driven via
//   continuous assignment from generate scope) so testbench hierarchical
//   references like dut.dot_acc[o] and dut.pre_relu[o] still work.
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
    // Module-level arrays (accessible via hierarchical path from testbenches)
    // Each element is driven by a continuous assignment from generate scope.
    // =========================================================================
    logic signed [63:0] dot_acc  [0:OUT_SIZE-1];   // raw dot products
    logic signed [63:0] pre_relu [0:OUT_SIZE-1];   // post-bias, pre-ReLU

    // =========================================================================
    // Per-neuron generate blocks
    //
    // Splitting into OUT_SIZE independent always_comb blocks lets Verilator
    // emit one C++ function per neuron (~IN_SIZE ops each) rather than one
    // giant function (~OUT_SIZE × IN_SIZE ops), which compiles far faster.
    //
    // Each instance g_neuron[o] owns:
    //   dot_g  — 64-bit private accumulator for neuron o
    // And drives (via continuous assignment):
    //   dot_acc[o], pre_relu[o], act_out[o]
    // =========================================================================
    generate
        for (genvar o = 0; o < OUT_SIZE; o++) begin : g_neuron

            logic signed [63:0] dot_g;  // private accumulator for this neuron

            // -----------------------------------------------------------------
            // Dot product: Σ act_in[i] × weights[o][i]
            // Both operands are sign-extended to 64-bit before multiplication.
            // -----------------------------------------------------------------
            always_comb begin
                dot_g = 64'sh0;
                for (int i = 0; i < IN_SIZE; i++)
                    dot_g = dot_g + 64'(signed'(act_in[i])) *
                                    64'(signed'(weights[o][i]));
            end

            // -----------------------------------------------------------------
            // Expose through module-level arrays (testbench observability)
            // and compute ReLU output.
            // -----------------------------------------------------------------
            assign dot_acc[o]  = dot_g;
            assign pre_relu[o] = dot_g + 64'(signed'(bias[o]));
            assign act_out[o]  = pre_relu[o][63] ? 32'sh0 : pre_relu[o][31:0];

        end
    endgenerate

endmodule : fc1_stage
