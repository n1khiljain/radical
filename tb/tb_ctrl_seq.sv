// =============================================================================
// tb_ctrl_seq.sv
// Testbench for ctrl_seq — full inference FSM sequencer
//
// =============================================================================
// TEST STRATEGY
// =============================================================================
//
//   All weights and the input image are set to zero, except fc2_b[3] = 100.
//   This makes every intermediate result analytically traceable:
//
//   1. All pixels = 0.
//   2. conv1: Σ(pixel × 0) = 0 for all outputs. ReLU(0) = 0. Pool(0) = 0.
//      conv1_buf = all 0.
//   3. conv2: Σ(0 × 0) = 0. ReLU(0) = 0. Pool(0) = 0.
//      conv2_buf = all 0.  flat_conv2 = all 0.
//   4. fc1:  dot(0, W=0) + bias(0) = 0. ReLU(0) = 0.
//      fc1_buf = all 0.
//   5. fc2:  dot(0, W=0) + bias[i] = bias[i].
//      fc2_out = [0, 0, 0, 100, 0, 0, 0, 0, 0, 0]
//   6. argmax: max=100 at index 3  →  predicted_class = 4'd3.
//
// =============================================================================
// VERIFICATION PHASES
// =============================================================================
//   Phase 1 : State transition monitoring (IDLE→RUN_CONV1→...→DONE→IDLE)
//   Phase 2 : busy is asserted throughout, deasserted at DONE
//   Phase 3 : done pulses for exactly one cycle after DONE state
//   Phase 4 : predicted_class = 4'd3 (from argmax of known fc2 output)
// =============================================================================

module tb_ctrl_seq;

    // -------------------------------------------------------------------------
    // State encoding constants (must match ctrl_seq.sv typedef)
    // -------------------------------------------------------------------------
    localparam int ST_IDLE      = 0;
    localparam int ST_RUN_CONV1 = 1;
    localparam int ST_RUN_CONV2 = 2;
    localparam int ST_RUN_FC1   = 3;
    localparam int ST_RUN_FC2   = 4;
    localparam int ST_ARGMAX    = 5;
    localparam int ST_DONE      = 6;
    localparam int ST_WAIT_FC1  = 7;   // fc1 is now multi-cycle

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clock, reset, start;
    logic        busy, done;

    logic [7:0]  image_in [0:783];

    logic signed [7:0]  conv1_w [0:7][0:2][0:2];
    logic signed [7:0]  conv2_w [0:15][0:7][0:2][0:2];
    logic signed [7:0]  fc1_w   [0:31][0:783];
    logic signed [31:0] fc1_b   [0:31];
    logic signed [7:0]  fc2_w   [0:9][0:31];
    logic signed [31:0] fc2_b   [0:9];

    logic signed [31:0] logits          [0:9];
    logic [3:0]         predicted_class;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    ctrl_seq dut (.*);

    // -------------------------------------------------------------------------
    // Clock — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 0;
    always  #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Checking utility
    // -------------------------------------------------------------------------
    integer fail_count;

    task automatic chk(
        input int          actual,
        input int          expected,
        input string       msg
    );
        if (actual !== expected) begin
            $display("LOG: %0t : ERROR : tb_ctrl_seq : %s : expected=%0d actual=%0d",
                     $time, msg, expected, actual);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_ctrl_seq : %s : value=%0d  OK",
                     $time, msg, actual);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Initialise all control signals
        // ------------------------------------------------------------------
        reset = 1'b1;
        start = 1'b0;

        // ------------------------------------------------------------------
        // Zero-initialise image and all weights
        // ------------------------------------------------------------------
        for (int i = 0; i < 784; i++) image_in[i] = 8'h0;

        for (int oc = 0; oc < 8; oc++)
            for (int kr = 0; kr < 3; kr++)
                for (int kc = 0; kc < 3; kc++)
                    conv1_w[oc][kr][kc] = 8'h0;

        for (int oc = 0; oc < 16; oc++)
            for (int ic = 0; ic < 8; ic++)
                for (int kr = 0; kr < 3; kr++)
                    for (int kc = 0; kc < 3; kc++)
                        conv2_w[oc][ic][kr][kc] = 8'h0;

        for (int o = 0; o < 32; o++) begin
            fc1_b[o] = 32'sh0;
            for (int i = 0; i < 784; i++)
                fc1_w[o][i] = 8'h0;
        end

        for (int o = 0; o < 10; o++) begin
            fc2_b[o] = 32'sh0;
            for (int i = 0; i < 32; i++)
                fc2_w[o][i] = 8'h0;
        end

        // ------------------------------------------------------------------
        // Set fc2_b[3] = 100 → fc2_out = [0,0,0,100,0,...] → argmax = 3
        // ------------------------------------------------------------------
        fc2_b[3] = 32'sd100;

        // ------------------------------------------------------------------
        // Release reset after 3 cycles
        // ------------------------------------------------------------------
        repeat(3) @(posedge clock);
        #1; reset = 1'b0;

        chk(int'(dut.state), ST_IDLE, "After reset: state=IDLE");
        chk(int'(busy),      0,       "After reset: busy=0");
        chk(int'(done),      0,       "After reset: done=0");

        // ==================================================================
        // Phase 1 — Start inference; monitor all state transitions
        // ==================================================================
        $display("--- Phase 1: FSM state transitions ---");

        start = 1'b1;
        @(posedge clock); #1;   // posedge: IDLE→RUN_CONV1, image_buf latched
        start = 1'b0;
        chk(int'(dut.state), ST_RUN_CONV1, "State = RUN_CONV1");
        chk(int'(busy),      1,            "busy asserted");

        @(posedge clock); #1;   // posedge: RUN_CONV1→RUN_CONV2, conv1_buf latched
        chk(int'(dut.state), ST_RUN_CONV2, "State = RUN_CONV2");

        @(posedge clock); #1;   // posedge: RUN_CONV2→RUN_FC1, conv2_buf latched
        chk(int'(dut.state), ST_RUN_FC1,   "State = RUN_FC1");

        @(posedge clock); #1;   // posedge: RUN_FC1→WAIT_FC1, fc1 launched
        chk(int'(dut.state), ST_WAIT_FC1,  "State = WAIT_FC1 (fc1 multi-cycle)");

        // fc1 now runs IN_SIZE+2 cycles; the FSM must stall here until fc1_done.
        // Poll (bounded) until it leaves WAIT_FC1 instead of assuming one cycle.
        begin
            integer guard;
            guard = 0;
            while (int'(dut.state) == ST_WAIT_FC1 && guard < 2000) begin
                @(posedge clock); #1;
                guard++;
            end
            $display("LOG: %0t : INFO  : tb_ctrl_seq : fc1 ran %0d cycle(s) in WAIT_FC1",
                     $time, guard);
        end
        chk(int'(dut.state), ST_RUN_FC2,   "State = RUN_FC2 (after fc1 done)");

        @(posedge clock); #1;   // posedge: RUN_FC2→ARGMAX, fc2_buf+logits latched
        chk(int'(dut.state), ST_ARGMAX,    "State = ARGMAX");

        @(posedge clock); #1;   // posedge: ARGMAX→DONE, predicted_class latched
        chk(int'(dut.state), ST_DONE,      "State = DONE");

        // ==================================================================
        // Phase 2+3 — DONE state: done pulses, busy clears, IDLE next cycle
        // ==================================================================
        $display("--- Phase 2+3: done pulse and busy deassertion ---");

        @(posedge clock); #1;   // posedge: DONE→IDLE, done=1, busy=0
        chk(int'(dut.state), ST_IDLE, "State returned to IDLE");
        chk(int'(done),      1,       "done = 1 (pulse)");
        chk(int'(busy),      0,       "busy = 0 (deasserted)");

        // done must be a one-cycle pulse — verify it clears next cycle
        @(posedge clock); #1;
        chk(int'(done), 0, "done = 0 (one-cycle pulse verified)");

        // ==================================================================
        // Phase 4 — predicted_class = 3 (argmax of [0,0,0,100,0,...,0])
        // ==================================================================
        $display("--- Phase 4: predicted_class and logits ---");

        chk(int'(predicted_class), 3, "predicted_class = 3");

        // Spot-check logits: index 3 must be 100, others 0
        chk(logits[0], 0,   "logits[0] = 0");
        chk(logits[3], 100, "logits[3] = 100 (winning class)");
        chk(logits[9], 0,   "logits[9] = 0");

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("ctrl_seq: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("ctrl_seq.fst");
        $dumpvars(0);
    end

endmodule : tb_ctrl_seq
