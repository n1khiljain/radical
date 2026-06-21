// =============================================================================
// tb_fc1_stage.sv
// Testbench for fc1_stage — dot product, bias add, and ReLU
//
// =============================================================================
// TEST CASE  (IN_SIZE=4, OUT_SIZE=2)
// =============================================================================
//
//   act_in = [1, 2, 3, 4]
//
//   weights[0] = [+1, +1, +1, +1]
//   weights[1] = [-1, +1, -1, +1]
//
//   bias[0] = +5
//   bias[1] = -20
//
// =============================================================================
// HAND-DERIVED EXPECTED VALUES
// =============================================================================
//
//   Neuron 0:
//     dot = 1×(+1) + 2×(+1) + 3×(+1) + 4×(+1) = 1+2+3+4 = 10
//     pre_relu = 10 + 5 = 15
//     act_out[0] = 15   (positive → ReLU pass-through)
//
//   Neuron 1:
//     dot = 1×(-1) + 2×(+1) + 3×(-1) + 4×(+1) = -1+2-3+4 = 2
//     pre_relu = 2 + (-20) = -18
//     act_out[1] = 0    (negative → ReLU clamps to 0)
//
// =============================================================================
// VERIFICATION PHASES
// =============================================================================
//  Phase 1 : dot_acc[]  — 2 checks  (raw dot product before bias)
//  Phase 2 : pre_relu[] — 2 checks  (post-bias 64-bit value)
//  Phase 3 : act_out[]  — 2 checks  (ReLU + 32-bit truncation)
// =============================================================================

module tb_fc1_stage;

    // -------------------------------------------------------------------------
    // Test parameters
    // -------------------------------------------------------------------------
    localparam int TB_IN  = 4;
    localparam int TB_OUT = 2;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic               clock;
    logic               reset;
    logic               start;
    logic               busy;
    logic               done;
    logic signed [31:0] act_in  [0:TB_IN-1];
    logic signed [7:0]  weights [0:TB_OUT-1][0:TB_IN-1];
    logic signed [31:0] bias    [0:TB_OUT-1];
    logic signed [31:0] act_out [0:TB_OUT-1];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    fc1_stage #(
        .IN_SIZE (TB_IN),
        .OUT_SIZE(TB_OUT)
    ) dut (
        .clock  (clock),
        .reset  (reset),
        .start  (start),
        .busy   (busy),
        .done   (done),
        .act_in (act_in),
        .weights(weights),
        .bias   (bias),
        .act_out(act_out)
    );

    // 10 ns clock
    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------------
        reset = 1'b1;
        start = 1'b0;
        @(posedge clock);
        @(posedge clock);
        reset = 1'b0;

        // ------------------------------------------------------------------
        // Apply stimulus (held stable through the whole run)
        // ------------------------------------------------------------------

        // act_in = [1, 2, 3, 4]
        act_in[0] = 32'sd1;
        act_in[1] = 32'sd2;
        act_in[2] = 32'sd3;
        act_in[3] = 32'sd4;

        // weights[0] = all +1
        weights[0][0] = 8'sd1;   weights[0][1] = 8'sd1;
        weights[0][2] = 8'sd1;   weights[0][3] = 8'sd1;

        // weights[1] = [-1, +1, -1, +1]
        weights[1][0] = 8'shFF;  // -1
        weights[1][1] = 8'sd1;
        weights[1][2] = 8'shFF;  // -1
        weights[1][3] = 8'sd1;

        // bias[0] = +5, bias[1] = -20
        bias[0] = 32'sd5;
        bias[1] = -32'sd20;

        // ------------------------------------------------------------------
        // Kick off the multi-cycle dot product and wait for done
        // ------------------------------------------------------------------
        @(posedge clock); #1;
        start = 1'b1;
        @(posedge clock); #1;
        start = 1'b0;

        // wait for done pulse (bounded so a wedged DUT can't hang the sim)
        begin
            integer guard;
            guard = 0;
            while (done !== 1'b1 && guard < 10000) begin
                @(posedge clock); #1;
                guard++;
            end
            if (done !== 1'b1) begin
                $display("LOG: %0t : ERROR : tb_fc1_stage : done never asserted", $time);
                fail_count++;
            end
        end

        // ==================================================================
        // Phase 1 — dot_acc: raw dot products (before bias)
        //   dot_acc[0] = 1+2+3+4 = 10
        //   dot_acc[1] = -1+2-3+4 = 2
        // ==================================================================
        $display("--- Phase 1: dot_acc (raw dot products) ---");

        if (dut.dot_acc[0] !== 64'sd10) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : dot_acc[0] : expected=10 actual=%0d",
                     $time, dut.dot_acc[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : dot_acc[0]=10  OK", $time);

        if (dut.dot_acc[1] !== 64'sd2) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : dot_acc[1] : expected=2 actual=%0d",
                     $time, dut.dot_acc[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : dot_acc[1]=2  OK", $time);

        // ==================================================================
        // Phase 2 — pre_relu: post-bias 64-bit values
        //   pre_relu[0] = 10 + 5  =  15
        //   pre_relu[1] = 2  - 20 = -18
        // ==================================================================
        $display("--- Phase 2: pre_relu (post-bias, 64-bit) ---");

        if (dut.pre_relu[0] !== 64'sd15) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : pre_relu[0] : expected=15 actual=%0d",
                     $time, dut.pre_relu[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : pre_relu[0]=15  OK", $time);

        if (dut.pre_relu[1] !== -64'sd18) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : pre_relu[1] : expected=-18 actual=%0d",
                     $time, dut.pre_relu[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : pre_relu[1]=-18  OK", $time);

        // ==================================================================
        // Phase 3 — act_out: ReLU + 32-bit truncation
        //   act_out[0] = 15   (positive → pass-through)
        //   act_out[1] = 0    (negative → clamped to 0)
        // ==================================================================
        $display("--- Phase 3: act_out (ReLU + 32-bit output) ---");

        if (act_out[0] !== 32'sd15) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : act_out[0] : expected=15 actual=%0d",
                     $time, act_out[0]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : act_out[0]=15  OK", $time);

        if (act_out[1] !== 32'sh0) begin
            $display("LOG: %0t : ERROR : tb_fc1_stage : act_out[1] : expected=0 actual=%0d",
                     $time, act_out[1]);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_fc1_stage : act_out[1]=0 (ReLU clamp)  OK", $time);

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("fc1_stage: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("fc1_stage.fst");
        $dumpvars(0);
    end

endmodule : tb_fc1_stage
