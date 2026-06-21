// =============================================================================
// tb_weight_loader.sv
// Testbench for weight_loader — integrates weight_mem + weight_loader
//
// Test pattern:
//   weight_mem preloaded:  mem[addr] = 8'(signed'(addr - 32))
//                          => values -32 .. +31  (addr 0..63)
//
//   Expected weights_out after done:
//     weights_out[row][col] = mem[row*8 + col]
//                           = 8'(signed'(row*8 + col - 32))
//
//     weights_out[0][0] = mem[ 0] = -32
//     weights_out[0][1] = mem[ 1] = -31
//     ...
//     weights_out[7][6] = mem[62] =  30
//     weights_out[7][7] = mem[63] =  31
//
// Sequence:
//   Cycles 1-2     : synchronous reset
//   Cycles 3-66    : preload weight_mem (write all 64 entries, wr_en=1)
//   Cycle  67      : wr_en=0 (write port idle)
//   Cycle  68      : pulse start=1 for one cycle
//   ~66 cycles     : loader sequences through weight_mem reads
//   done pulse     : check all 64 weights_out entries
// =============================================================================

module tb_weight_loader;

    // -------------------------------------------------------------------------
    // Signals
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;

    // weight_mem write port (driven by testbench for preload)
    logic                   wr_en;
    logic        [5:0]      wr_addr;
    logic signed [7:0]      wr_data;

    // weight_mem → weight_loader read bus
    logic        [5:0]      rd_addr;
    logic signed [7:0]      rd_data;

    // weight_loader control
    logic                   start;
    logic                   done;

    // weight_loader output
    logic signed [7:0]      weights_out [0:7][0:7];

    // -------------------------------------------------------------------------
    // DUT instantiation — weight_mem
    // -------------------------------------------------------------------------
    weight_mem u_weight_mem (
        .clock   (clock),
        .reset   (reset),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    // -------------------------------------------------------------------------
    // DUT instantiation — weight_loader
    // -------------------------------------------------------------------------
    weight_loader u_weight_loader (
        .clock       (clock),
        .reset       (reset),
        .start       (start),
        .done        (done),
        .rd_addr     (rd_addr),
        .rd_data     (rd_data),
        .weights_out (weights_out)
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
        #5000;
        $fatal(1, "TIMEOUT: simulation exceeded safety limit — done signal never arrived");
    end

    // -------------------------------------------------------------------------
    // Helper function: expected data value for a flat address
    // -------------------------------------------------------------------------
    function automatic logic signed [7:0] expected_val (input int addr);
        return 8'(signed'(addr - 32));
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    integer fail_count;

    initial begin
        $display("TEST START");

        fail_count = 0;

        // ------------------------------------------------------------------
        // Initialise all signals
        // ------------------------------------------------------------------
        reset   = 1'b1;
        wr_en   = 1'b0;
        wr_addr = 6'h00;
        wr_data = 8'sd0;
        start   = 1'b0;

        // ------------------------------------------------------------------
        // Hold reset for 2 cycles
        // ------------------------------------------------------------------
        @(posedge clock); #1;
        @(posedge clock); #1;
        reset = 1'b0;

        // ------------------------------------------------------------------
        // TEST 1 — Preload weight_mem: write all 64 entries
        //   mem[addr] = addr - 32  (-32 .. +31)
        // ------------------------------------------------------------------
        $display("--- Preloading weight_mem ---");
        wr_en = 1'b1;
        for (int i = 0; i < 64; i++) begin
            wr_addr = 6'(i);
            wr_data = expected_val(i);
            @(posedge clock); #1;
        end
        wr_en = 1'b0;

        // One idle cycle after writes
        @(posedge clock); #1;

        // ------------------------------------------------------------------
        // TEST 2 — Trigger weight_loader with a one-cycle start pulse
        // ------------------------------------------------------------------
        $display("--- Starting weight_loader ---");
        start = 1'b1;
        @(posedge clock); #1;
        start = 1'b0;

        // ------------------------------------------------------------------
        // Wait for done pulse
        // (loader takes ~66 cycles from start detection to done assertion)
        // ------------------------------------------------------------------
        @(posedge done);
        #1;   // Small skew past the posedge to let NBA updates settle

        $display("--- done received — checking weights_out ---");

        // ------------------------------------------------------------------
        // TEST 3 — Verify all 64 positions of weights_out
        // ------------------------------------------------------------------
        for (int row = 0; row < 8; row++) begin
            for (int col = 0; col < 8; col++) begin
                automatic int flat_addr  = row * 8 + col;
                automatic logic signed [7:0] exp = expected_val(flat_addr);

                if (weights_out[row][col] !== exp) begin
                    $display("LOG: %0t : ERROR : tb_weight_loader : weights_out[%0d][%0d] : expected_value: %0d actual_value: %0d",
                             $time, row, col, exp, weights_out[row][col]);
                    fail_count++;
                end else begin
                    $display("LOG: %0t : INFO : tb_weight_loader : weights_out[%0d][%0d] : expected_value: %0d actual_value: %0d",
                             $time, row, col, exp, weights_out[row][col]);
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
            $error("weight_loader testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated due to weights_out mismatch(es)");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("weight_loader.fst");
        $dumpvars(0);
    end

endmodule : tb_weight_loader
