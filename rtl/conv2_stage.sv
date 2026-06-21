// =============================================================================
// conv2_stage.sv
// Conv Layer 2: IN_CH input channels → OUT_CH output channels
//
// Pipeline (fully combinational):
//   1. Zero-pad each input channel activation map by 1 on each side
//   2. 3×3 convolution, stride 1, padding 1 — accumulate across all IN_CH
//      input channels → 32-bit signed accumulator per output pixel
//   3. ReLU: clamp negative values to 0
//   4. 2×2 max-pool, stride 2 → feature_out
//
// Default parameters match the second conv layer of a LeNet/MNIST model:
//   IN_CH=8, IN_ROWS=14, IN_COLS=14, OUT_CH=16 → 16×7×7 output
//
// Input activations:
//   32-bit signed integers carried from conv1 (no requantization, Option 1).
//   After conv1's ReLU the values are non-negative; the wide port accommodates
//   the full 19-bit (or wider) accumulator range from the upstream layer.
//
// Accumulator sizing (confirmed by architecture analysis):
//   Per-product worst case: act_in ≤ 145,161 (conv1 peak) × weight ≤ 127
//                           = 18,435,447 < 2^25
//   72 products (IN_CH=8 × 9 positions): 72 × 18.4 M ≈ 1.33 B < 2^31
//   Required: 26-bit minimum; 32-bit signed used for margin.
//
// Constraints: IN_ROWS and IN_COLS must be even (2×2 pool requires integer dims).
// =============================================================================

module conv2_stage #(
    parameter int IN_CH   = 8,
    parameter int IN_ROWS = 14,
    parameter int IN_COLS = 14,
    parameter int OUT_CH  = 16
) (
    // 32-bit signed activations from the upstream layer (one map per channel)
    input  logic signed [31:0] act_in      [0:IN_CH-1][0:IN_ROWS-1][0:IN_COLS-1],
    // INT8 kernel weights: [out_ch][in_ch][kernel_row][kernel_col]
    input  logic signed [7:0]  kernel_w    [0:OUT_CH-1][0:IN_CH-1][0:2][0:2],
    // 32-bit signed post-pool output
    output logic signed [31:0] feature_out [0:OUT_CH-1][0:(IN_ROWS/2)-1][0:(IN_COLS/2)-1]
);

    localparam int POOL_ROWS = IN_ROWS / 2;
    localparam int POOL_COLS = IN_COLS / 2;

    // =========================================================================
    // Internal arrays
    // =========================================================================

    // Per-channel zero-padded activation maps
    logic signed [31:0] padded    [0:IN_CH-1][0:IN_ROWS+1][0:IN_COLS+1];

    // Post-convolution accumulators: accumulated across all IN_CH input channels
    logic signed [31:0] conv_acc  [0:OUT_CH-1][0:IN_ROWS-1][0:IN_COLS-1];

    // Post-ReLU feature maps
    logic signed [31:0] conv_relu [0:OUT_CH-1][0:IN_ROWS-1][0:IN_COLS-1];

    // Shared temporaries — sequentially valid inside always_comb
    logic signed [31:0] px32, kw32, prod32, acc_tmp;
    logic signed [31:0] p00_t, p01_t, p10_t, p11_t, m0_t, m1_t;

    // =========================================================================
    // Step 1 — Zero-pad each input channel
    // =========================================================================
    always_comb begin
        for (int ic = 0; ic < IN_CH; ic++) begin
            for (int r = 0; r < IN_ROWS+2; r++) begin
                for (int c = 0; c < IN_COLS+2; c++) begin
                    if (r == 0 || r == IN_ROWS+1 || c == 0 || c == IN_COLS+1)
                        padded[ic][r][c] = 32'sh0;
                    else
                        padded[ic][r][c] = act_in[ic][r-1][c-1];
                end
            end
        end
    end

    // =========================================================================
    // Step 2 — 3×3 convolution, stride 1, accumulated across all input channels
    //
    // conv_acc[oc][r][c] = Σ_{ic} Σ_{kr=0..2} Σ_{kc=0..2}
    //                        padded[ic][r+kr][c+kc] × kernel_w[oc][ic][kr][kc]
    //
    // Product sizing:
    //   px32 (32-bit) × kw32 (8→32-bit sign-extended) → 32-bit product
    //   Max per-product: 18.4 M (fits in 32 bits)
    //   Max sum over 72 products: ≈1.33 B < 2^31 (32-bit signed) ✓
    // =========================================================================
    always_comb begin
        for (int oc = 0; oc < OUT_CH; oc++) begin
            for (int r = 0; r < IN_ROWS; r++) begin
                for (int c = 0; c < IN_COLS; c++) begin
                    acc_tmp = 32'sh0;
                    for (int ic = 0; ic < IN_CH; ic++) begin
                        for (int kr = 0; kr < 3; kr++) begin
                            for (int kc = 0; kc < 3; kc++) begin
                                px32    = padded[ic][r+kr][c+kc];
                                kw32    = kernel_w[oc][ic][kr][kc]; // sign-extends 8→32
                                prod32  = px32 * kw32;
                                acc_tmp = acc_tmp + prod32;
                            end
                        end
                    end
                    conv_acc[oc][r][c] = acc_tmp;
                end
            end
        end
    end

    // =========================================================================
    // Step 3 — ReLU: clamp negative 32-bit values to 0
    //
    // The sign bit of a 32-bit two's-complement value is bit [31].
    // =========================================================================
    always_comb begin
        for (int oc = 0; oc < OUT_CH; oc++) begin
            for (int r = 0; r < IN_ROWS; r++) begin
                for (int c = 0; c < IN_COLS; c++) begin
                    conv_relu[oc][r][c] = conv_acc[oc][r][c][31] ?
                                          32'sh0 : conv_acc[oc][r][c];
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
        for (int oc = 0; oc < OUT_CH; oc++) begin
            for (int pr = 0; pr < POOL_ROWS; pr++) begin
                for (int pc = 0; pc < POOL_COLS; pc++) begin
                    p00_t = conv_relu[oc][2*pr+0][2*pc+0];
                    p01_t = conv_relu[oc][2*pr+0][2*pc+1];
                    p10_t = conv_relu[oc][2*pr+1][2*pc+0];
                    p11_t = conv_relu[oc][2*pr+1][2*pc+1];
                    m0_t  = (p00_t >= p01_t) ? p00_t : p01_t;
                    m1_t  = (p10_t >= p11_t) ? p10_t : p11_t;
                    feature_out[oc][pr][pc] = (m0_t >= m1_t) ? m0_t : m1_t;
                end
            end
        end
    end

endmodule : conv2_stage
