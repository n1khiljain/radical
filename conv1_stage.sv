// =============================================================================
// conv1_stage.sv
// Conv Layer 1: 1 input channel → OUT_CH output channels
//
// Pipeline (fully combinational):
//   1. Zero-pad input by 1 on each side
//   2. 3×3 convolution, stride 1, padding 1 → 19-bit signed accumulator
//   [TODO: rescale/requantize to INT8 — see marked block below]
//   3. ReLU: clamp negative values to 0
//   4. 2×2 max-pool, stride 2 → feature_out
//
// Default parameters match the first conv layer of a LeNet/MNIST model:
//   IN_ROWS=28, IN_COLS=28, OUT_CH=8 → 14×14×8 output
//
// Parameters must satisfy: IN_ROWS and IN_COLS are even (for integer pool dims).
//
// Accumulator sizing:
//   INT8 × INT8 product range: [-128×127, 127×127] = [-16256, 16129]  → 16-bit
//   9 products summed:          9 × 16129 = 145161 < 2^18             → 19-bit ✓
//
// Output width is 19-bit signed (not yet quantized to INT8 — see TODO block).
// =============================================================================

module conv1_stage #(
    parameter int IN_ROWS = 28,
    parameter int IN_COLS = 28,
    parameter int OUT_CH  = 8
) (
    input  logic signed [7:0]  pixel_in    [0:IN_ROWS-1][0:IN_COLS-1],
    input  logic signed [7:0]  kernel_w    [0:OUT_CH-1][0:2][0:2],
    output logic signed [18:0] feature_out [0:OUT_CH-1][0:(IN_ROWS/2)-1][0:(IN_COLS/2)-1]
);

    localparam int POOL_ROWS = IN_ROWS / 2;
    localparam int POOL_COLS = IN_COLS / 2;

    // =========================================================================
    // Internal arrays
    // =========================================================================

    // Zero-padded input: (IN_ROWS+2) × (IN_COLS+2)
    logic signed [7:0]  padded     [0:IN_ROWS+1][0:IN_COLS+1];

    // Post-convolution accumulators: OUT_CH × IN_ROWS × IN_COLS
    logic signed [18:0] conv_acc   [0:OUT_CH-1][0:IN_ROWS-1][0:IN_COLS-1];

    // Post-ReLU feature maps: same shape
    logic signed [18:0] conv_relu  [0:OUT_CH-1][0:IN_ROWS-1][0:IN_COLS-1];

    // Shared temporaries — sequentially valid inside always_comb
    logic signed [15:0] px16, kw16;
    logic signed [18:0] prod19, acc_tmp;
    logic signed [18:0] p00_t, p01_t, p10_t, p11_t, m0_t, m1_t;

    // =========================================================================
    // Step 1 — Zero-pad input
    // =========================================================================
    always_comb begin
        for (int r = 0; r < IN_ROWS+2; r++) begin
            for (int c = 0; c < IN_COLS+2; c++) begin
                if (r == 0 || r == IN_ROWS+1 || c == 0 || c == IN_COLS+1)
                    padded[r][c] = 8'sh00;
                else
                    padded[r][c] = pixel_in[r-1][c-1];
            end
        end
    end

    // =========================================================================
    // Step 2 — 3×3 convolution, stride 1
    //
    // conv_acc[ch][r][c] = Σ_{kr=0}^{2} Σ_{kc=0}^{2}
    //                        padded[r+kr][c+kc] × kernel_w[ch][kr][kc]
    //
    // Sign extension:
    //   padded element → px16 (logic signed [7:0] auto-extends to [15:0])
    //   kernel weight  → kw16 (same)
    //   px16 × kw16    → 16-bit product (range ≤ 16,129 in magnitude, no trunc)
    //   product → prod19 (sign-extended to 19-bit for accumulation)
    // =========================================================================
    always_comb begin
        for (int ch = 0; ch < OUT_CH; ch++) begin
            for (int r = 0; r < IN_ROWS; r++) begin
                for (int c = 0; c < IN_COLS; c++) begin
                    acc_tmp = 19'sh00000;
                    for (int kr = 0; kr < 3; kr++) begin
                        for (int kc = 0; kc < 3; kc++) begin
                            px16    = padded[r+kr][c+kc];
                            kw16    = kernel_w[ch][kr][kc];
                            prod19  = px16 * kw16;
                            acc_tmp = acc_tmp + prod19;
                        end
                    end
                    conv_acc[ch][r][c] = acc_tmp;
                end
            end
        end
    end

    // =========================================================================
    // TODO: PER-LAYER RESCALE AND REQUANTIZE TO INT8
    // =========================================================================
    //
    // After quantization-aware training (QAT), the 19-bit accumulator value in
    // conv_acc must be rescaled and re-quantized to INT8 before being fed to
    // ReLU and subsequent layers.  This step has NOT been implemented pending
    // confirmation from the model-export side of the following:
    //
    //   1. Per-channel output scale factors S_out[ch]
    //      These combine: S_in (input scale) × S_weight[ch] / S_out_desired[ch]
    //      Typically represented as a fixed-point multiplier + right-shift.
    //
    //   2. Zero-point convention (symmetric vs. asymmetric quantization)
    //      Symmetric: output range [-128, 127], no zero-point offset.
    //      Asymmetric: output range [0, 255] with a zero-point shift.
    //
    //   3. Rounding mode
    //      Common choices: round-half-to-even (banker's), truncation, round-half-up.
    //
    //   4. Placement relative to ReLU
    //      For most QAT flows: requantize first, then ReLU clips negatives.
    //      When implemented, move this step BETWEEN conv_acc and conv_relu,
    //      and change the intermediate array type from [18:0] to [7:0].
    //
    // When this step is inserted:
    //   - Add a `scale [0:OUT_CH-1]` input port (fixed-point scale factors)
    //   - Replace conv_relu source from conv_acc to the INT8-quantized output
    //   - Change feature_out output width from [18:0] to [7:0]
    //   - Remove the 19-bit conv_relu array
    //
    // =========================================================================

    // =========================================================================
    // Step 3 — ReLU: clamp negative 19-bit values to 0
    //
    // The sign bit of a 19-bit two's-complement value is bit [18].
    // =========================================================================
    always_comb begin
        for (int ch = 0; ch < OUT_CH; ch++) begin
            for (int r = 0; r < IN_ROWS; r++) begin
                for (int c = 0; c < IN_COLS; c++) begin
                    conv_relu[ch][r][c] = conv_acc[ch][r][c][18] ?
                                          19'sh00000 : conv_acc[ch][r][c];
                end
            end
        end
    end

    // =========================================================================
    // Step 4 — 2×2 max-pool, stride 2
    //
    // Pool window [2*pr : 2*pr+1][2*pc : 2*pc+1] → single output pixel
    // =========================================================================
    always_comb begin
        for (int ch = 0; ch < OUT_CH; ch++) begin
            for (int pr = 0; pr < POOL_ROWS; pr++) begin
                for (int pc = 0; pc < POOL_COLS; pc++) begin
                    p00_t = conv_relu[ch][2*pr+0][2*pc+0];
                    p01_t = conv_relu[ch][2*pr+0][2*pc+1];
                    p10_t = conv_relu[ch][2*pr+1][2*pc+0];
                    p11_t = conv_relu[ch][2*pr+1][2*pc+1];
                    m0_t  = (p00_t >= p01_t) ? p00_t : p01_t;
                    m1_t  = (p10_t >= p11_t) ? p10_t : p11_t;
                    feature_out[ch][pr][pc] = (m0_t >= m1_t) ? m0_t : m1_t;
                end
            end
        end
    end

endmodule : conv1_stage
