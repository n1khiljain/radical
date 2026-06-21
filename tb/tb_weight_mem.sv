// =============================================================================
// tb_weight_mem.sv
// Testbench for weight_mem — 64-entry INT8 synchronous SRAM
//
// Test pattern (hand-defined):
//   Write phase : addr 0..63, data[addr] = 8'(signed'(addr - 32))
//                 Maps to the signed range  -32 .. +31
//                 Exercises both negative and positive INT8 values.
//
//   Read phase  : read back addr 0..63 sequentially (rd_addr pipelined one
//                 cycle ahead of the expected check due to 1-cycle read latency)
//
//   Expected    : rd_data == 8'(signed'(addr - 32)) for each address
//
// Sequence:
//   Cycle  1       : reset=1  — output register cleared
//   Cycles 2..65   : write all 64 entries (wr_en=1, addr 0..63)
//   Cycles 66..130 : read all 64 entries; check each with one-cycle offset
// =============================================================================

module tb_weight_mem;

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;
    logic                   wr_en;
    logic        [5:0]      wr_addr;
    logic signed [7:0]      wr_data;
    logic        [5:0]      rd_addr;
    logic signed [7:0]      rd_data;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    weight_mem dut (
        .clock   (clock),
        .reset   (reset),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
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
        #3000;
        $fatal(1, "TIMEOUT: simulation exceeded safety limit");
    end

    // -------------------------------------------------------------------------
    // Helper function: expected data for a given address
    // -------------------------------------------------------------------------
    function automatic logic signed [7:0] expected_data (input logic [5:0] addr);
        return 8'(signed'({2'b00, addr} - 7'd32));
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    integer fail_count;
    logic signed [7:0] exp_val;

    initial begin
        $display("TEST START");

        fail_count = 0;

        // ------------------------------------------------------------------
        // Initialise signals
        // ------------------------------------------------------------------
        reset   = 1'b1;
        wr_en   = 1'b0;
        wr_addr = 6'h00;
        wr_data = 8'sd0;
        rd_addr = 6'h00;

        // ------------------------------------------------------------------
        // TEST 1 — Reset check: rd_data must be 0 after reset
        // ------------------------------------------------------------------
        @(posedge clock); #1;   // Cycle 1: reset captured

        if (rd_data !== 8'sd0) begin
            $display("LOG: %0t : ERROR : tb_weight_mem : reset check : expected_value: 0 actual_value: %0d",
                     $time, rd_data);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO : tb_weight_mem : reset check : expected_value: 0 actual_value: %0d",
                     $time, rd_data);
        end

        reset = 1'b0;

        // ------------------------------------------------------------------
        // TEST 2 — Write phase: write addr 0..63, data = addr - 32
        // ------------------------------------------------------------------
        $display("--- Write phase ---");
        wr_en = 1'b1;

        for (int i = 0; i < 64; i++) begin
            wr_addr = 6'(i);
            wr_data = expected_data(6'(i));
            @(posedge clock); #1;   // Write captured on posedge
        end

        wr_en = 1'b0;

        // ------------------------------------------------------------------
        // TEST 3 — Read-back phase
        //
        // rd_data has 1-cycle latency: present rd_addr[k] one cycle before
        // checking rd_data[k].
        //
        // Cycle structure:
        //   present rd_addr[0]  → posedge → rd_data[0] available next cycle
        //   present rd_addr[1]  → posedge → rd_data[0] checked; rd_data[1] latching
        //   ...
        //   present rd_addr[63] → posedge → rd_data[62] checked
        //   idle                → posedge → rd_data[63] checked
        // ------------------------------------------------------------------
        $display("--- Read-back phase ---");

        // Pre-load first address before the loop
        rd_addr = 6'h00;
        @(posedge clock); #1;   // Latch address 0

        for (int i = 1; i < 64; i++) begin
            rd_addr = 6'(i);    // Next address

            // Check result for address i-1 (available now, 1 cycle after presented)
            exp_val = expected_data(6'(i - 1));

            if (rd_data !== exp_val) begin
                $display("LOG: %0t : ERROR : tb_weight_mem : rd_addr[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i - 1, exp_val, rd_data);
                fail_count++;
            end else begin
                $display("LOG: %0t : INFO : tb_weight_mem : rd_addr[%0d] : expected_value: %0d actual_value: %0d",
                         $time, i - 1, exp_val, rd_data);
            end

            @(posedge clock); #1;
        end

        // Final address (63) — check after last posedge
        exp_val = expected_data(6'd63);
        if (rd_data !== exp_val) begin
            $display("LOG: %0t : ERROR : tb_weight_mem : rd_addr[63] : expected_value: %0d actual_value: %0d",
                     $time, exp_val, rd_data);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO : tb_weight_mem : rd_addr[63] : expected_value: %0d actual_value: %0d",
                     $time, exp_val, rd_data);
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("weight_mem testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated due to read-back mismatch(es)");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("weight_mem.fst");
        $dumpvars(0);
    end

endmodule : tb_weight_mem
