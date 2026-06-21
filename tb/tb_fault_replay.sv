// =============================================================================
// tb_fault_replay.sv
// Testbench for fault_replay — fault injection schedule engine
//
// =============================================================================
// TEST TOPOLOGY
// =============================================================================
//
//   tb_fault_replay (top)
//     u_weight_mem  : weight_mem    — 64-entry × 8-bit signed SRAM
//     u_fault_replay: fault_replay  — fault injection engine
//
//   fault_replay accesses u_weight_mem.mem via:
//     tb_fault_replay.u_weight_mem.mem[addr]
//
// =============================================================================
// FAULT SCHEDULE (written inline at t=0, read by fault_replay at t=1)
// =============================================================================
//
//   Event  Cycle  mem_id  addr  bit_idx  Description
//   -----  -----  ------  ----  -------  ---------------------------------
//     0      10      0      5      3     flip bit 3 of mem[5]
//     1      15      0     10      0     flip bit 0 of mem[10]
//     2      20      0      5      7     flip bit 7 of mem[5] (same addr, diff bit)
//     3      25      0     20      2     flip bit 2 of mem[20]
//
// Pre-initialised memory (written via write port after reset):
//   mem[ 5] = 8'hAA = 8'b10101010  → bit3=1, bit7=1
//   mem[10] = 8'h0F = 8'b00001111  → bit0=1
//   mem[20] = 8'h55 = 8'b01010101  → bit2=1
//
// Expected post-fault values (cumulative):
//   After cycle 10 event: mem[ 5] = 8'hAA ^ 8'h08 = 8'hA2  (bit3 flipped)
//   After cycle 15 event: mem[10] = 8'h0F ^ 8'h01 = 8'h0E  (bit0 flipped)
//   After cycle 20 event: mem[ 5] = 8'hA2 ^ 8'h80 = 8'h22  (bit7 flipped on top)
//   After cycle 25 event: mem[20] = 8'h55 ^ 8'h04 = 8'h51  (bit2 flipped)
//
// =============================================================================
// CYCLE COUNTER MAPPING
// =============================================================================
//
//   fault_replay's cycle_count starts at 0 and increments each posedge once
//   reset deasserts.
//
//   Fault fires at posedge where cycle_count (before increment) == event.cycle.
//   So event at cycle N fires at the (N+1)-th posedge after reset deassert.
//
//   Testbench tracks posedges-after-reset with tb_cyc (increments after #1).
//   Relationship: at tb_cyc == N+1, cycle_count just became N+1 and the fault
//   for event.cycle == N has fired.
//
//   "Not-before" check: at tb_cyc == N,  fault has NOT yet fired
//   "Exactly-right" check: at tb_cyc == N+1, fault HAS fired
// =============================================================================

module tb_fault_replay;

    // -------------------------------------------------------------------------
    // DUT: weight_mem signals
    // -------------------------------------------------------------------------
    logic               clock;
    logic               reset;
    logic               wr_en;
    logic [5:0]         wr_addr;
    logic signed [7:0]  wr_data;
    logic [5:0]         rd_addr;
    logic signed [7:0]  rd_data;

    // -------------------------------------------------------------------------
    // weight_mem instantiation
    // -------------------------------------------------------------------------
    weight_mem u_weight_mem (
        .clock  (clock),
        .reset  (reset),
        .wr_en  (wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_addr(rd_addr),
        .rd_data(rd_data)
    );

    // -------------------------------------------------------------------------
    // fault_replay instantiation
    // -------------------------------------------------------------------------
    fault_replay #(
        .FAULT_FILE("faults.txt"),
        .MAX_EVENTS(16)
    ) u_fault_replay (
        .clock(clock),
        .reset(reset)
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
        $fatal(1, "TIMEOUT: simulation exceeded safety limit");
    end

    // -------------------------------------------------------------------------
    // Cycle counter (tracks posedges after reset deassert)
    // -------------------------------------------------------------------------
    integer tb_cyc;

    // -------------------------------------------------------------------------
    // Fail counter
    // -------------------------------------------------------------------------
    integer fail_count;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;
        tb_cyc     = 0;

        // ------------------------------------------------------------------
        // Step 0 — Write fault schedule file at t=0
        //           fault_replay reads it at t=1 (after its #1 delay)
        // ------------------------------------------------------------------
        begin
            automatic integer fd;
            fd = $fopen("faults.txt", "w");
            if (fd == 0) $fatal(1, "Could not create faults.txt");
            // cycle  mem_id  addr  bit_idx
            $fdisplay(fd, "10  0   5  3");
            $fdisplay(fd, "15  0  10  0");
            $fdisplay(fd, "20  0   5  7");
            $fdisplay(fd, "25  0  20  2");
            $fclose(fd);
            $display("TB: fault schedule written to faults.txt (4 events)");
        end

        // ------------------------------------------------------------------
        // Step 1 — Reset (5 cycles)
        // ------------------------------------------------------------------
        reset   = 1'b1;
        wr_en   = 1'b0;
        wr_addr = 6'h00;
        wr_data = 8'sh00;
        rd_addr = 6'h00;

        repeat (5) @(posedge clock);
        #1; reset = 1'b0;
        // tb_cyc = 0 (reset just deasserted, cycle_count = 0)

        // ------------------------------------------------------------------
        // Step 2 — Initialise memory:
        //   mem[ 5] = 8'hAA,  mem[10] = 8'h0F,  mem[20] = 8'h55
        //   (3 write cycles, tb_cyc becomes 1,2,3)
        // ------------------------------------------------------------------
        $display("TB: initialising memory locations 5, 10, 20");

        wr_en = 1'b1;

        // tb_cyc = 1: write addr 5
        wr_addr = 6'd5;  wr_data = 8'shAA;
        @(posedge clock); #1; tb_cyc++;

        // tb_cyc = 2: write addr 10
        wr_addr = 6'd10; wr_data = 8'sh0F;
        @(posedge clock); #1; tb_cyc++;

        // tb_cyc = 3: write addr 20
        wr_addr = 6'd20; wr_data = 8'sh55;
        @(posedge clock); #1; tb_cyc++;

        wr_en = 1'b0;

        // ------------------------------------------------------------------
        // Step 3 — Advance to tb_cyc = 10 (cycle_count = 10), one cycle
        //          BEFORE fault event 0 fires (fires at tb_cyc = 11)
        // ------------------------------------------------------------------
        // Need 7 more posedges to go from tb_cyc=3 to tb_cyc=10
        repeat (7) begin
            @(posedge clock); #1; tb_cyc++;
        end
        // tb_cyc = 10, cycle_count = 10, event at cycle 10 NOT YET fired

        // *** "not before" check for event 0 ***
        if (u_weight_mem.mem[5] !== 8'hAA) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : PRE_EVENT0 : mem[5] expected AA got %0h (fault fired early!)",
                     $time, u_weight_mem.mem[5]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : PRE_EVENT0 : mem[5]=AA correct (no early fault)  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // Advance one more cycle — fault event 0 fires here (cycle_count=10)
        // ------------------------------------------------------------------
        @(posedge clock); #1; tb_cyc++;
        // tb_cyc = 11, cycle_count = 11, fault 0 has fired

        // *** "exactly right cycle" check for event 0 ***
        // Expected: mem[5] = 8'hAA ^ 8'h08 = 8'hA2 (bit 3 flipped)
        if (u_weight_mem.mem[5] !== 8'hA2) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : POST_EVENT0 : mem[5] expected A2 got %0h",
                     $time, u_weight_mem.mem[5]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : POST_EVENT0 : mem[5]=A2 (bit3 flipped)  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // Advance to tb_cyc = 15 (cycle_count = 15), before event 1 fires
        // ------------------------------------------------------------------
        repeat (4) begin
            @(posedge clock); #1; tb_cyc++;
        end
        // tb_cyc = 15

        // *** "not before" check for event 1 ***
        if (u_weight_mem.mem[10] !== 8'h0F) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : PRE_EVENT1 : mem[10] expected 0F got %0h",
                     $time, u_weight_mem.mem[10]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : PRE_EVENT1 : mem[10]=0F correct  OK", $time);
        end

        // Advance one cycle — event 1 fires (cycle_count = 15)
        @(posedge clock); #1; tb_cyc++;
        // tb_cyc = 16

        // *** "exactly right cycle" check for event 1 ***
        // Expected: mem[10] = 8'h0F ^ 8'h01 = 8'h0E (bit 0 flipped)
        if (u_weight_mem.mem[10] !== 8'h0E) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : POST_EVENT1 : mem[10] expected 0E got %0h",
                     $time, u_weight_mem.mem[10]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : POST_EVENT1 : mem[10]=0E (bit0 flipped)  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // Advance to tb_cyc = 20, before event 2 fires
        // ------------------------------------------------------------------
        repeat (4) begin
            @(posedge clock); #1; tb_cyc++;
        end
        // tb_cyc = 20

        // *** "not before" check for event 2 (mem[5] should still be A2) ***
        if (u_weight_mem.mem[5] !== 8'hA2) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : PRE_EVENT2 : mem[5] expected A2 got %0h",
                     $time, u_weight_mem.mem[5]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : PRE_EVENT2 : mem[5]=A2 correct  OK", $time);
        end

        // Advance one cycle — event 2 fires (cycle_count = 20)
        @(posedge clock); #1; tb_cyc++;
        // tb_cyc = 21

        // *** "exactly right cycle" check for event 2 ***
        // Expected: mem[5] = 8'hA2 ^ 8'h80 = 8'h22 (bit 7 flipped on top of prior A2)
        if (u_weight_mem.mem[5] !== 8'h22) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : POST_EVENT2 : mem[5] expected 22 got %0h",
                     $time, u_weight_mem.mem[5]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : POST_EVENT2 : mem[5]=22 (bit7 flipped)  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // Advance to tb_cyc = 25, before event 3 fires
        // ------------------------------------------------------------------
        repeat (4) begin
            @(posedge clock); #1; tb_cyc++;
        end
        // tb_cyc = 25

        // *** "not before" check for event 3 ***
        if (u_weight_mem.mem[20] !== 8'h55) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : PRE_EVENT3 : mem[20] expected 55 got %0h",
                     $time, u_weight_mem.mem[20]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : PRE_EVENT3 : mem[20]=55 correct  OK", $time);
        end

        // Advance one cycle — event 3 fires (cycle_count = 25)
        @(posedge clock); #1; tb_cyc++;
        // tb_cyc = 26

        // *** "exactly right cycle" check for event 3 ***
        // Expected: mem[20] = 8'h55 ^ 8'h04 = 8'h51 (bit 2 flipped)
        if (u_weight_mem.mem[20] !== 8'h51) begin
            $display("LOG: %0t : ERROR : tb_fault_replay : POST_EVENT3 : mem[20] expected 51 got %0h",
                     $time, u_weight_mem.mem[20]);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_fault_replay : POST_EVENT3 : mem[20]=51 (bit2 flipped)  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("fault_replay testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("fault_replay.fst");
        $dumpvars(0);
    end

endmodule : tb_fault_replay
