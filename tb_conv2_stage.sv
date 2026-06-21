// =============================================================================
// tb_conv2_stage.sv
// Testbench for conv2_stage — cross-channel conv accumulation, ReLU, 2×2 pool
//
// =============================================================================
// TEST CONFIGURATION
// =============================================================================
//
//   DUT parameters: IN_CH=2, IN_ROWS=4, IN_COLS=4, OUT_CH=2
//
// =============================================================================
// INPUT ACTIVATION MAPS (32-bit signed)
// =============================================================================
//
//   act_in[IC=0] (4×4):          act_in[IC=1] (4×4):
//     1 1 1 1                      0 0 0 0
//     1 2 2 1                      0 1 1 0
//     1 2 2 1                      0 1 1 0
//     1 1 1 1                      0 0 0 0
//
// =============================================================================
// KERNELS (INT8)
// =============================================================================
//
//   kernel_w[OC=0][IC=0] = all +1 (3×3)
//   kernel_w[OC=0][IC=1] = all +2 (3×3)
//   kernel_w[OC=1][IC=0] = all -1 (3×3)
//   kernel_w[OC=1][IC=1] = all -2 (3×3)
//
// =============================================================================
// HAND-DERIVED EXPECTED VALUES
// =============================================================================
//
// Zero-padded act_in[IC=0] (6×6):       Zero-padded act_in[IC=1] (6×6):
//   0 0 0 0 0 0                          0 0 0 0 0 0
//   0 1 1 1 1 0                          0 0 0 0 0 0
//   0 1 2 2 1 0                          0 0 1 1 0 0
//   0 1 2 2 1 0                          0 0 1 1 0 0
//   0 1 1 1 1 0                          0 0 0 0 0 0
//   0 0 0 0 0 0                          0 0 0 0 0 0
//
// IC=0 contribution (all-+1 kernel) — 3×3 neighbourhood sums:
//    5  8  8  5
//    8 13 13  8
//    8 13 13  8
//    5  8  8  5
//
// IC=1 contribution (all-+2 kernel) — 2 × neighbourhood sums of IC=1:
//   IC=1 neighbourhood sums:         × 2:
//    1  2  2  1                       2  4  4  2
//    2  4  4  2                       4  8  8  4
//    2  4  4  2                       4  8  8  4
//    1  2  2  1                       2  4  4  2
//
// conv_acc[OC=0] = IC=0 contribution + IC=1 contribution:
//    5+2   8+4   8+4   5+2    =   7  12  12   7
//    8+4  13+8  13+8   8+4    =  12  21  21  12
//    8+4  13+8  13+8   8+4    =  12  21  21  12
//    5+2   8+4   8+4   5+2    =   7  12  12   7
//
// conv_relu[OC=0]: all values > 0 → unchanged from conv_acc[OC=0]
//
// conv_acc[OC=1] = -(conv_acc[OC=0]):   (all-(-1) and all-(-2) kernels)
//   -7 -12 -12  -7
//  -12 -21 -21 -12
//  -12 -21 -21 -12
//   -7 -12 -12  -7
//
// conv_relu[OC=1]: all values < 0 → clamped to 0 by ReLU
//
// feature_out (2×2 max-pool, stride 2):
//   OC=0:
//     pool[0][0] = max( 7, 12, 12, 21) = 21
//     pool[0][1] = max(12,  7, 21, 12) = 21
//     pool[1][0] = max(12, 21,  7, 12) = 21
//     pool[1][1] = max(21, 12, 12,  7) = 21
//   OC=1: all zeros → pool outputs all 0
//
// =============================================================================
// VERIFICATION PHASES
// =============================================================================
//  Phase 1 : conv_acc[OC=0]   — 16 checks  (cross-channel accumulation)
//  Phase 2 : conv_relu[OC=0]  — 16 checks  (ReLU pass-through, all positive)
//  Phase 3 : conv_relu[OC=1]  — 16 checks  (ReLU clamp, all negative → 0)
//  Phase 4 : feature_out       —  8 checks  (2×2 max-pool, both output channels)
// =============================================================================

module tb_conv2_stage;

    // -------------------------------------------------------------------------
    // Test parameters
    // -------------------------------------------------------------------------
    localparam int TB_IN_CH   = 2;
    localparam int TB_IN_ROWS = 4;
    localparam int TB_IN_COLS = 4;
    localparam int TB_OUT_CH  = 2;
    localparam int TB_POOL_R  = TB_IN_ROWS / 2;
    localparam int TB_POOL_C  = TB_IN_COLS / 2;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic signed [31:0] act_in      [0:TB_IN_CH-1][0:TB_IN_ROWS-1][0:TB_IN_COLS-1];
    logic signed [7:0]  kernel_w    [0:TB_OUT_CH-1][0:TB_IN_CH-1][0:2][0:2];
    logic signed [31:0] feature_out [0:TB_OUT_CH-1][0:TB_POOL_R-1][0:TB_POOL_C-1];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    conv2_stage #(
        .IN_CH  (TB_IN_CH),
        .IN_ROWS(TB_IN_ROWS),
        .IN_COLS(TB_IN_COLS),
        .OUT_CH (TB_OUT_CH)
    ) dut (
        .act_in     (act_in),
        .kernel_w   (kernel_w),
        .feature_out(feature_out)
    );

    // -------------------------------------------------------------------------
    // Expected-value table for conv_acc[OC=0] (hand-derived, see header)
    // -------------------------------------------------------------------------
    logic signed [31:0] exp_acc0 [0:TB_IN_ROWS-1][0:TB_IN_COLS-1];

    integer fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Build expected conv_acc[OC=0] table
        // ------------------------------------------------------------------
        exp_acc0[0][0] = 32'sd7;   exp_acc0[0][1] = 32'sd12;
        exp_acc0[0][2] = 32'sd12;  exp_acc0[0][3] = 32'sd7;
        exp_acc0[1][0] = 32'sd12;  exp_acc0[1][1] = 32'sd21;
        exp_acc0[1][2] = 32'sd21;  exp_acc0[1][3] = 32'sd12;
        exp_acc0[2][0] = 32'sd12;  exp_acc0[2][1] = 32'sd21;
        exp_acc0[2][2] = 32'sd21;  exp_acc0[2][3] = 32'sd12;
        exp_acc0[3][0] = 32'sd7;   exp_acc0[3][1] = 32'sd12;
        exp_acc0[3][2] = 32'sd12;  exp_acc0[3][3] = 32'sd7;

        // ------------------------------------------------------------------
        // Apply act_in stimulus
        // ------------------------------------------------------------------

        // IC=0: border=1, centre=2
        act_in[0][0][0] = 32'sd1;  act_in[0][0][1] = 32'sd1;
        act_in[0][0][2] = 32'sd1;  act_in[0][0][3] = 32'sd1;
        act_in[0][1][0] = 32'sd1;  act_in[0][1][1] = 32'sd2;
        act_in[0][1][2] = 32'sd2;  act_in[0][1][3] = 32'sd1;
        act_in[0][2][0] = 32'sd1;  act_in[0][2][1] = 32'sd2;
        act_in[0][2][2] = 32'sd2;  act_in[0][2][3] = 32'sd1;
        act_in[0][3][0] = 32'sd1;  act_in[0][3][1] = 32'sd1;
        act_in[0][3][2] = 32'sd1;  act_in[0][3][3] = 32'sd1;

        // IC=1: inner 2×2 = 1, rest = 0
        act_in[1][0][0] = 32'sd0;  act_in[1][0][1] = 32'sd0;
        act_in[1][0][2] = 32'sd0;  act_in[1][0][3] = 32'sd0;
        act_in[1][1][0] = 32'sd0;  act_in[1][1][1] = 32'sd1;
        act_in[1][1][2] = 32'sd1;  act_in[1][1][3] = 32'sd0;
        act_in[1][2][0] = 32'sd0;  act_in[1][2][1] = 32'sd1;
        act_in[1][2][2] = 32'sd1;  act_in[1][2][3] = 32'sd0;
        act_in[1][3][0] = 32'sd0;  act_in[1][3][1] = 32'sd0;
        act_in[1][3][2] = 32'sd0;  act_in[1][3][3] = 32'sd0;

        // ------------------------------------------------------------------
        // Set kernels
        // ------------------------------------------------------------------

        // OC=0: IC=0 → all +1, IC=1 → all +2
        for (int kr = 0; kr < 3; kr++) begin
            for (int kc = 0; kc < 3; kc++) begin
                kernel_w[0][0][kr][kc] = 8'sd1;
                kernel_w[0][1][kr][kc] = 8'sd2;
            end
        end

        // OC=1: IC=0 → all -1, IC=1 → all -2
        for (int kr = 0; kr < 3; kr++) begin
            for (int kc = 0; kc < 3; kc++) begin
                kernel_w[1][0][kr][kc] = 8'shFF;   // -1 in 8-bit signed
                kernel_w[1][1][kr][kc] = 8'shFE;   // -2 in 8-bit signed
            end
        end

        #1;   // Allow combinational logic to settle

        // ==================================================================
        // Phase 1 — conv_acc[OC=0]: cross-channel accumulation
        //   IC=0 (k=+1) + IC=1 (k=+2) → hand-derived table above
        // ==================================================================
        $display("--- Phase 1: conv_acc[OC=0] (cross-channel: IC0×+1 + IC1×+2) ---");
        for (int r = 0; r < TB_IN_ROWS; r++) begin
            for (int c = 0; c < TB_IN_COLS; c++) begin
                if (dut.conv_acc[0][r][c] !== exp_acc0[r][c]) begin
                    $display("LOG: %0t : ERROR : tb_conv2_stage : dut.conv_acc[0][%0d][%0d] : expected=%0d actual=%0d",
                             $time, r, c, exp_acc0[r][c], dut.conv_acc[0][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv2_stage : dut.conv_acc[0][%0d][%0d] : value=%0d  OK",
                             $time, r, c, dut.conv_acc[0][r][c]);
                end
            end
        end

        // ==================================================================
        // Phase 2 — conv_relu[OC=0]: ReLU pass-through (all values positive)
        //   Must equal conv_acc[OC=0] exactly (no clamping)
        // ==================================================================
        $display("--- Phase 2: conv_relu[OC=0] (ReLU pass-through, all positive) ---");
        for (int r = 0; r < TB_IN_ROWS; r++) begin
            for (int c = 0; c < TB_IN_COLS; c++) begin
                if (dut.conv_relu[0][r][c] !== exp_acc0[r][c]) begin
                    $display("LOG: %0t : ERROR : tb_conv2_stage : dut.conv_relu[0][%0d][%0d] : expected=%0d actual=%0d",
                             $time, r, c, exp_acc0[r][c], dut.conv_relu[0][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv2_stage : dut.conv_relu[0][%0d][%0d] : value=%0d  OK",
                             $time, r, c, dut.conv_relu[0][r][c]);
                end
            end
        end

        // ==================================================================
        // Phase 3 — conv_relu[OC=1]: ReLU clamp
        //   OC=1 uses all-(-1)/all-(-2) kernels → all accumulations negative
        //   → every output clamped to 0
        // ==================================================================
        $display("--- Phase 3: conv_relu[OC=1] (all-negative accumulation, ReLU clamps to 0) ---");
        for (int r = 0; r < TB_IN_ROWS; r++) begin
            for (int c = 0; c < TB_IN_COLS; c++) begin
                if (dut.conv_relu[1][r][c] !== 32'sh0) begin
                    $display("LOG: %0t : ERROR : tb_conv2_stage : dut.conv_relu[1][%0d][%0d] : expected=0 actual=%0d",
                             $time, r, c, dut.conv_relu[1][r][c]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv2_stage : dut.conv_relu[1][%0d][%0d] : value=0  OK",
                             $time, r, c);
                end
            end
        end

        // ==================================================================
        // Phase 4 — feature_out: 2×2 max-pool output
        //   OC=0: all four 2×2 windows have peak 21 → all pool outputs = 21
        //   OC=1: all ReLU outputs were 0 → all pool outputs = 0
        // ==================================================================
        $display("--- Phase 4: feature_out (2x2 max-pool, stride 2) ---");
        for (int pr = 0; pr < TB_POOL_R; pr++) begin
            for (int pc = 0; pc < TB_POOL_C; pc++) begin

                // OC=0: expect 21
                if (feature_out[0][pr][pc] !== 32'sd21) begin
                    $display("LOG: %0t : ERROR : tb_conv2_stage : feature_out[0][%0d][%0d] : expected=21 actual=%0d",
                             $time, pr, pc, feature_out[0][pr][pc]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv2_stage : feature_out[0][%0d][%0d] : value=21  OK",
                             $time, pr, pc);
                end

                // OC=1: expect 0
                if (feature_out[1][pr][pc] !== 32'sh0) begin
                    $display("LOG: %0t : ERROR : tb_conv2_stage : feature_out[1][%0d][%0d] : expected=0 actual=%0d",
                             $time, pr, pc, feature_out[1][pr][pc]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO  : tb_conv2_stage : feature_out[1][%0d][%0d] : value=0  OK",
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
            $error("conv2_stage: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("conv2_stage.fst");
        $dumpvars(0);
    end

endmodule : tb_conv2_stage
