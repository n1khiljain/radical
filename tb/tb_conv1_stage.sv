// =============================================================================
// tb_conv1_stage.sv
// Testbench for conv1_stage — verifies convolution, ReLU, and 2×2 max-pool
//
// =============================================================================
// TEST CASE — 4×4 input (hand-computable slice, not full 28×28)
// =============================================================================
//
//  DUT parameters used here: IN_ROWS=4, IN_COLS=4, OUT_CH=2
//
//  Input pixel_in (4×4, INT8):
//    1 1 1 1
//    1 2 2 1
//    1 2 2 1
//    1 1 1 1
//
//  Zero-padded (6×6 after pad=1):
//    0 0 0 0 0 0
//    0 1 1 1 1 0
//    0 1 2 2 1 0
//    0 1 2 2 1 0
//    0 1 1 1 1 0
//    0 0 0 0 0 0
//
//  kernel_w[0] = all +1 (3×3)     kernel_w[1] = all -1 (3×3)
//
// =============================================================================
// HAND-DERIVED EXPECTED VALUES
// =============================================================================
//
//  conv_acc[0] — 3×3 neighbourhood sum (all-+1 kernel):
//    out[r][c] = Σ padded[r:r+2][c:c+2]
//
//    [0][0] = (0+0+0)+(0+1+1)+(0+1+2) =  5
//    [0][1] = (0+0+0)+(1+1+1)+(1+2+2) =  8
//    [0][2] = (0+0+0)+(1+1+1)+(2+2+1) =  8
//    [0][3] = (0+0+0)+(1+1+0)+(2+1+0) =  5
//    [1][0] = (0+1+1)+(0+1+2)+(0+1+2) =  8
//    [1][1] = (1+1+1)+(1+2+2)+(1+2+2) = 13
//    [1][2] = (1+1+1)+(2+2+1)+(2+2+1) = 13
//    [1][3] = (1+1+0)+(2+1+0)+(2+1+0) =  8
//    [2][0] = (0+1+2)+(0+1+2)+(0+1+1) =  8
//    [2][1] = (1+2+2)+(1+2+2)+(1+1+1) = 13
//    [2][2] = (2+2+1)+(2+2+1)+(1+1+1) = 13
//    [2][3] = (2+1+0)+(2+1+0)+(1+1+0) =  8
//    [3][0] = (0+1+2)+(0+1+1)+(0+0+0) =  5
//    [3][1] = (1+2+2)+(1+1+1)+(0+0+0) =  8
//    [3][2] = (2+2+1)+(1+1+1)+(0+0+0) =  8
//    [3][3] = (2+1+0)+(1+1+0)+(0+0+0) =  5
//
//    Grid:   5  8  8  5
//            8 13 13  8
//            8 13 13  8
//            5  8  8  5
//
//  conv_relu[0]: all values ≥ 0 → unchanged from conv_acc[0]
//
//  conv_acc[1] = −conv_acc[0]  (all-(-1) kernel)
//    Grid:  -5  -8  -8  -5
//           -8 -13 -13  -8
//           -8 -13 -13  -8
//           -5  -8  -8  -5
//
//  conv_relu[1]: all values < 0 → clamped to 0 by ReLU
//    Grid:   0  0  0  0
//            0  0  0  0
//            0  0  0  0
//            0  0  0  0
//
//  feature_out (2×2 max-pool, stride 2):
//    ch=0:
//      pool[0][0] = max(5,8,8,13)  = 13
//      pool[0][1] = max(8,5,13,8)  = 13
//      pool[1][0] = max(8,13,5,8)  = 13
//      pool[1][1] = max(13,8,8,5)  = 13
//    ch=1:  all = max(0,0,0,0) = 0
//
// =============================================================================
// VERIFICATION PHASES
// =============================================================================
//  Phase 1 : conv_acc[0]  — 16 checks  (convolution correctness)
//  Phase 2 : conv_relu[0] — 16 checks  (ReLU pass-through for positive values)
//  Phase 3 : conv_relu[1] — 16 checks  (ReLU clamp for all-negative values)
//  Phase 4 : feature_out  —  8 checks  (2×2 max-pool, both channels)
// =============================================================================

module tb_conv1_stage;

    // -------------------------------------------------------------------------
    // Test parameters
    // -------------------------------------------------------------------------
    localparam int TB_ROWS   = 4;
    localparam int TB_COLS   = 4;
    localparam int TB_CH     = 2;
    localparam int TB_POOL_R = TB_ROWS / 2;
    localparam int TB_POOL_C = TB_COLS / 2;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic signed [7:0]  pixel_in    [0:TB_ROWS-1][0:TB_COLS-1];
    logic signed [7:0]  kernel_w    [0:TB_CH-1][0:2][0:2];
    logic signed [18:0] feature_out [0:TB_CH-1][0:TB_POOL_R-1][0:TB_POOL_C-1];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    conv1_stage #(
        .IN_ROWS(TB_ROWS),
        .IN_COLS(TB_COLS),
        .OUT_CH (TB_CH)
    ) dut (
        .pixel_in   (pixel_in),
        .kernel_w   (kernel_w),
        .feature_out(feature_out)
    );

    // -------------------------------------------------------------------------
    // Expected-value tables
    // -------------------------------------------------------------------------
    logic signed [18:0] exp_acc0 [0:TB_ROWS-1][0:TB_COLS-1];

    integer fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Build expected conv_acc[0] table (hand-derived, see header)
        // ------------------------------------------------------------------
        exp_acc0[0][0] = 19'sd5;  exp_acc0[0][1] = 19'sd8;
        exp_acc0[0][2] = 19'sd8;  exp_acc0[0][3] = 19'sd5;
        exp_acc0[1][0] = 19'sd8;  exp_acc0[1][1] = 19'sd13;
        exp_acc0[1][2] = 19'sd13; exp_acc0[1][3] = 19'sd8;
        exp_acc0[2][0] = 19'sd8;  exp_acc0[2][1] = 19'sd13;
        exp_acc0[2][2] = 19'sd13; exp_acc0[2][3] = 19'sd8;
        exp_acc0[3][0] = 19'sd5;  exp_acc0[3][1] = 19'sd8;
        exp_acc0[3][2] = 19'sd8;  exp_acc0[3][3] = 19'sd5;

        // ------------------------------------------------------------------
        // Apply 4×4 input stimulus
        // ------------------------------------------------------------------
        pixel_in[0][0] = 8'sd1;  pixel_in[0][1] = 8'sd1;
        pixel_in[0][2] = 8'sd1;  pixel_in[0][3] = 8'sd1;
        pixel_in[1][0] = 8'sd1;  pixel_in[1][1] = 8'sd2;
        pixel_in[1][2] = 8'sd2;  pixel_in[1][3] = 8'sd1;
        pixel_in[2][0] = 8'sd1;  pixel_in[2][1] = 8'sd2;
        pixel_in[2][2] = 8'sd2;  pixel_in[2][3] = 8'sd1;
        pixel_in[3][0] = 8'sd1;  pixel_in[3][1] = 8'sd1;
        pixel_in[3][2] = 8'sd1;  pixel_in[3][3] = 8'sd1;

        // ------------------------------------------------------------------
        // Set kernels:  ch=0 → all +1,  ch=1 → all -1 (8'shFF)
        // ------------------------------------------------------------------
        for (int kr = 0; kr < 3; kr++) begin
            for (int kc = 0; kc < 3; kc++) begin
                kernel_w[0][kr][kc] = 8'sd1;
                kernel_w[1][kr][kc] = 8'shFF;   // -1 in 8-bit signed two's complement
            end
        end

        #1;   // Allow combinational logic to settle

        // ==================================================================
        // Phase 1 — conv_acc[0]: convolution with all-+1 kernel
        // ==================================================================
        $display("--- Phase 1: conv_acc[0] (all-+1 kernel, expected neighbourhood sums) ---");
        for (int r = 0; r < TB_ROWS; r++) begin
            for (int c = 0; c < TB_COLS; c++) begin
                if (dut.conv_acc[0][r][c] !== exp_acc0[r][c]) begin
                    $display("LOG: %0t : ERROR : tb_conv1_stage : dut.conv_acc[0][%0d][%0d] : expected_value: %0d actual_value: %0d",
                             $time, r, c, exp_acc0[r][c], dut.conv_acc[0][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv1_stage : dut.conv_acc[0][%0d][%0d] : expected_value: %0d actual_value: %0d  OK",
                             $time, r, c, exp_acc0[r][c], dut.conv_acc[0][r][c]);
                end
            end
        end

        // ==================================================================
        // Phase 2 — conv_relu[0]: ReLU pass-through (all values positive)
        //           Must equal conv_acc[0] exactly (no clamping)
        // ==================================================================
        $display("--- Phase 2: conv_relu[0] (ReLU pass-through, all positive) ---");
        for (int r = 0; r < TB_ROWS; r++) begin
            for (int c = 0; c < TB_COLS; c++) begin
                if (dut.conv_relu[0][r][c] !== exp_acc0[r][c]) begin
                    $display("LOG: %0t : ERROR : tb_conv1_stage : dut.conv_relu[0][%0d][%0d] : expected_value: %0d actual_value: %0d",
                             $time, r, c, exp_acc0[r][c], dut.conv_relu[0][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv1_stage : dut.conv_relu[0][%0d][%0d] : expected_value: %0d actual_value: %0d  OK",
                             $time, r, c, exp_acc0[r][c], dut.conv_relu[0][r][c]);
                end
            end
        end

        // ==================================================================
        // Phase 3 — conv_relu[1]: ReLU clamp (all-(-1) kernel → all negative)
        //           Every output must be clamped to 0 by ReLU
        // ==================================================================
        $display("--- Phase 3: conv_relu[1] (all-(-1) kernel, ReLU clamps everything to 0) ---");
        for (int r = 0; r < TB_ROWS; r++) begin
            for (int c = 0; c < TB_COLS; c++) begin
                if (dut.conv_relu[1][r][c] !== 19'sh00000) begin
                    $display("LOG: %0t : ERROR : tb_conv1_stage : dut.conv_relu[1][%0d][%0d] : expected_value: 0 actual_value: %0d",
                             $time, r, c, dut.conv_relu[1][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv1_stage : dut.conv_relu[1][%0d][%0d] : expected_value: 0 actual_value: 0  OK",
                             $time, r, c);
                end
            end
        end

        // ==================================================================
        // Phase 4 — feature_out: 2×2 max-pool output
        //   ch=0: every pool cell = 13  (peak value dominates every 2×2 window)
        //   ch=1: every pool cell = 0   (all inputs zeroed by ReLU)
        // ==================================================================
        $display("--- Phase 4: feature_out (2x2 max-pool, stride 2) ---");
        for (int pr = 0; pr < TB_POOL_R; pr++) begin
            for (int pc = 0; pc < TB_POOL_C; pc++) begin

                // Channel 0: expect 13
                if (feature_out[0][pr][pc] !== 19'sd13) begin
                    $display("LOG: %0t : ERROR : tb_conv1_stage : dut.feature_out[0][%0d][%0d] : expected_value: 13 actual_value: %0d",
                             $time, pr, pc, feature_out[0][pr][pc]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv1_stage : dut.feature_out[0][%0d][%0d] : expected_value: 13 actual_value: 13  OK",
                             $time, pr, pc);
                end

                // Channel 1: expect 0
                if (feature_out[1][pr][pc] !== 19'sh00000) begin
                    $display("LOG: %0t : ERROR : tb_conv1_stage : dut.feature_out[1][%0d][%0d] : expected_value: 0 actual_value: %0d",
                             $time, pr, pc, feature_out[1][pr][pc]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv1_stage : dut.feature_out[1][%0d][%0d] : expected_value: 0 actual_value: 0  OK",
                             $time, pr, pc);
                end

            end
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("conv1_stage: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("conv1_stage.fst");
        $dumpvars(0);
    end

endmodule : tb_conv1_stage
