// =============================================================================
// tb_accel_top.sv
// Testbench for accel_top — full integration: weight_mem + weight_loader
//                           + mac_array
//
// Test stimulus (hand-computed):
//
//   Weight matrix loaded into weight_mem (row-major):
//     mem[addr] = addr − 32   (addr 0..63)
//     weights[i][j] = i*8 + j − 32
//
//     weights[0] = [−32,−31,−30,−29,−28,−27,−26,−25]
//     weights[1] = [−24,−23,−22,−21,−20,−19,−18,−17]
//     ...
//     weights[7] = [ 24, 25, 26, 27, 28, 29, 30, 31]
//
//   Activations:
//     A = [1, 2, 3, 4, 5, 6, 7, 8]
//
//   Expected result for row i  (hand-derived):
//
//     results[i] = Σ_{j=0}^{7} weights[i][j] * activations[j]
//                = Σ_{j=0}^{7} (8i + j − 32) * (j+1)
//                = (8i − 32) * Σ(j+1)  +  Σ j*(j+1)
//                = (8i − 32) * 36      +  168
//                = 288*i − 984
//
//     results[0] = 288*0 − 984 = −984
//     results[1] = 288*1 − 984 = −696
//     results[2] = 288*2 − 984 = −408
//     results[3] = 288*3 − 984 = −120
//     results[4] = 288*4 − 984 =  168
//     results[5] = 288*5 − 984 =  456
//     results[6] = 288*6 − 984 =  744
//     results[7] = 288*7 − 984 = 1032
//
//   Verification of Σ(j+1)  = 1+2+3+4+5+6+7+8          = 36
//   Verification of Σj(j+1) = 0+2+6+12+20+30+42+56      = 168
//   Spot-check row 0: −32−62−90−116−140−162−182−200      = −984 ✓
//   Spot-check row 7:  24+50+78+108+140+174+210+248      = 1032 ✓
//
// Sequence:
//   Cycles 1-2  : synchronous reset
//   Cycles 3-66 : preload weight_mem (wr_en=1, addr 0..63)
//   Cycle  67   : idle (wr_en=0)
//   Cycle  68   : pulse start=1 (activations held throughout)
//   ~68 cycles  : loader runs + MAC result registered
//   done pulse  : check results[0..7]
// =============================================================================

module tb_accel_top;

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;

    // Host weight-memory write port
    logic                   wr_en;
    logic        [5:0]      wr_addr;
    logic signed [7:0]      wr_data;

    // Control
    logic                   start;
    logic                   done;

    // Activation input and results output
    logic signed [7:0]      activations [0:7];
    logic signed [18:0]     results     [0:7];

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    accel_top dut (
        .clock       (clock),
        .reset       (reset),
        .wr_en       (wr_en),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .start       (start),
        .done        (done),
        .activations (activations),
        .results     (results)
    );

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #10000;
        $fatal(1, "TIMEOUT: simulation exceeded safety limit — done never arrived");
    end

    // -------------------------------------------------------------------------
    // Helper: weight value for flat address k
    // -------------------------------------------------------------------------
    function automatic logic signed [7:0] weight_val (input int k);
        return 8'(signed'(k - 32));
    endfunction

    // -------------------------------------------------------------------------
    // Hand-computed expected MAC result for row i
    //   results[i] = 288*i − 984
    // -------------------------------------------------------------------------
    function automatic logic signed [18:0] expected_result (input int i);
        return 19'(signed'(288 * i - 984));
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    integer fail_count;

    initial begin
        $display("TEST START");

        fail_count = 0;

        // ------------------------------------------------------------------
        // Initialise
        // ------------------------------------------------------------------
        reset       = 1'b1;
        wr_en       = 1'b0;
        wr_addr     = 6'h00;
        wr_data     = 8'sd0;
        start       = 1'b0;

        // Activations: A = [1, 2, 3, 4, 5, 6, 7, 8] — held throughout
        for (int k = 0; k < 8; k++) begin
            activations[k] = 8'(signed'(k + 1));
        end

        // ------------------------------------------------------------------
        // Reset — 2 cycles
        // ------------------------------------------------------------------
        @(posedge clock); #1;
        @(posedge clock); #1;
        reset = 1'b0;

        // ------------------------------------------------------------------
        // TEST 1 — Preload weight_mem (64 entries, row-major)
        //   mem[k] = k − 32
        // ------------------------------------------------------------------
        $display("--- Preloading weight_mem ---");
        wr_en = 1'b1;
        for (int k = 0; k < 64; k++) begin
            wr_addr = 6'(k);
            wr_data = weight_val(k);
            @(posedge clock); #1;
        end
        wr_en = 1'b0;

        // Idle cycle before start
        @(posedge clock); #1;

        // ------------------------------------------------------------------
        // TEST 2 — Pulse start; activations already applied
        // ------------------------------------------------------------------
        $display("--- Pulsing start ---");
        start = 1'b1;
        @(posedge clock); #1;
        start = 1'b0;

        // ------------------------------------------------------------------
        // Wait for done
        // done fires ~68 cycles after start:
        //   66 cycles (weight_loader) + 1 cycle (mac_array output FF)
        //   + 1 cycle (accel_top done register)
        // ------------------------------------------------------------------
        @(posedge done);
        #1;

        $display("--- done received — checking MAC results ---");

        // ------------------------------------------------------------------
        // TEST 3 — Verify results[0..7] against hand-computed values
        // ------------------------------------------------------------------
        for (int i = 0; i < 8; i++) begin
            automatic logic signed [18:0] exp = expected_result(i);

            if (results[i] !== exp) begin
                $display("LOG: %0t : ERROR : tb_accel_top : results[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i, exp, results[i]);
                fail_count++;
            end else begin
                $display("LOG: %0t : INFO : tb_accel_top : results[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i, exp, results[i]);
            end
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("accel_top testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated due to result mismatch(es)");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("accel_top.fst");
        $dumpvars(0);
    end

endmodule : tb_accel_top
