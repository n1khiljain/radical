// =============================================================================
// tb_scrubber.sv
// Unit testbench for scrubber.sv
//
// =============================================================================
// TEST STRATEGY
// =============================================================================
//
//   Small dimensions for fast local Verilator compile:
//     MEM_DEPTH=8, SCRUB_INTERVAL=4
//
//   Sequence:
//     1. Reset.  During reset, write a known byte (WRITE_VAL = 0x55) to
//        CORRUPT_ADDR=3 via the memory's write port.
//     2. Directly corrupt one bit of the stored 13-bit codeword via
//        hierarchical reference to u_mem.mem[CORRUPT_ADDR], simulating
//        a single-event upset.
//     3. Release reset.  Scrubber starts its first pass after SCRUB_INTERVAL=4
//        idle cycles.
//     4. Wait enough cycles for the scrubber to reach CORRUPT_ADDR and
//        complete the correction (WRITING state).
//     5. Verify:
//          a. scrub_correction pulsed for exactly one cycle.
//          b. A re-read of CORRUPT_ADDR yields WRITE_VAL with no error.
//
// =============================================================================

module tb_scrubber;

    // -------------------------------------------------------------------------
    // Parameters matching the DUT under test
    // -------------------------------------------------------------------------
    localparam int ADDR_BITS     = 15;
    localparam int MEM_DEPTH     = 8;          // small for fast sim
    localparam int SCRUB_INTERVAL = 4;         // small for fast sim

    localparam int  CORRUPT_ADDR = 3;          // address whose bit we flip
    localparam int  CORRUPT_BIT  = 4;          // which codeword bit to flip
    localparam logic [7:0] WRITE_VAL = 8'h55;  // known data byte

    // -------------------------------------------------------------------------
    // DUT + memory control signals
    // -------------------------------------------------------------------------
    logic        clock, reset;

    // Scrubber read port -> memory read port
    logic [14:0]          scrub_rd_addr;
    logic signed [7:0]    scrub_rd_data;
    logic [1:0]           scrub_rd_status;

    // Scrubber write port -> memory write port (muxed with tb writes below)
    logic                 scrub_wr_en;
    logic [14:0]          scrub_wr_addr;
    logic signed [7:0]    scrub_wr_data;

    // Telemetry
    logic                 scrub_correction;

    // Testbench write port (used only during init)
    logic                 tb_wr_en;
    logic [14:0]          tb_wr_addr;
    logic signed [7:0]    tb_wr_data;

    // Memory write port (OR of tb and scrubber; they never conflict in time)
    logic                 mem_wr_en;
    logic [14:0]          mem_wr_addr;
    logic signed [7:0]    mem_wr_data;

    assign mem_wr_en   = tb_wr_en | scrub_wr_en;
    assign mem_wr_addr = tb_wr_en  ? tb_wr_addr  : scrub_wr_addr;
    assign mem_wr_data = tb_wr_en  ? tb_wr_data  : scrub_wr_data;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    scrubber #(
        .ADDR_BITS    (ADDR_BITS),
        .MEM_DEPTH    (MEM_DEPTH),
        .SCRUB_INTERVAL(SCRUB_INTERVAL)
    ) dut (
        .clock           (clock),
        .reset           (reset),
        .scrub_rd_addr   (scrub_rd_addr),
        .scrub_rd_data   (scrub_rd_data),
        .scrub_rd_status (scrub_rd_status),
        .scrub_wr_en     (scrub_wr_en),
        .scrub_wr_addr   (scrub_wr_addr),
        .scrub_wr_data   (scrub_wr_data),
        .scrub_correction(scrub_correction)
    );

    // -------------------------------------------------------------------------
    // Memory instantiation
    // -------------------------------------------------------------------------
    weight_mem_ecc u_mem (
        .clock          (clock),
        .reset          (reset),
        .wr_en          (mem_wr_en),
        .wr_addr        (mem_wr_addr),
        .wr_data        (mem_wr_data),
        .rd_addr        (scrub_rd_addr),
        .rd_data        (scrub_rd_data),
        .rd_error_status(scrub_rd_status)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 0;
    always  #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    integer fail_count;

    task automatic chk(
        input int  actual,
        input int  expected,
        input string msg
    );
        if (actual !== expected) begin
            $display("LOG: %0t : ERROR : tb_scrubber : %s : expected=%0d actual=%0d",
                     $time, msg, expected, actual);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_scrubber : %s : value=%0d  OK",
                     $time, msg, actual);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count  = 0;
        tb_wr_en    = 1'b0;
        tb_wr_addr  = '0;
        tb_wr_data  = 8'sh0;
        reset       = 1'b1;

        // ------------------------------------------------------------------
        // Phase 1: Write WRITE_VAL to CORRUPT_ADDR while still in reset.
        // weight_mem_ecc writes on posedge clock regardless of reset,
        // so the data lands even while the scrubber is held in reset.
        // ------------------------------------------------------------------
        @(posedge clock); #1;
        tb_wr_en   = 1'b1;
        tb_wr_addr = 15'(CORRUPT_ADDR);
        tb_wr_data = signed'(WRITE_VAL);

        @(posedge clock); #1;  // posedge: memory latches {3'b000, enc_codeword}
        tb_wr_en = 1'b0;

        // ------------------------------------------------------------------
        // Phase 2: Inject a single-bit upset.
        // Flip bit CORRUPT_BIT of the stored 16-bit word directly.
        // This corrupts the ECC codeword, causing the next read to report
        // status=01 (single-bit correctable error).
        // ------------------------------------------------------------------
        u_mem.mem[CORRUPT_ADDR] = u_mem.mem[CORRUPT_ADDR] ^ (16'b1 << CORRUPT_BIT);

        $display("LOG: %0t : INFO  : tb_scrubber : injected SEU at mem[%0d] bit %0d",
                 $time, CORRUPT_ADDR, CORRUPT_BIT);
        $display("LOG: %0t : INFO  : tb_scrubber : corrupted word = 0x%04X",
                 $time, u_mem.mem[CORRUPT_ADDR]);

        // ------------------------------------------------------------------
        // Phase 3: Release reset.  Scrubber enters IDLE and counts down
        // SCRUB_INTERVAL=4 cycles, then walks addresses 0..7.
        // Expected timeline (cycles after reset release):
        //   0-3  : IDLE (counting down from 4 to 0)
        //   4    : IDLE -> READING addr 0
        //   5    : CHECKING addr 0 (no error)
        //   6    : READING addr 1
        //   7    : CHECKING addr 1 (no error)
        //   8    : READING addr 2
        //   9    : CHECKING addr 2 (no error)
        //   10   : READING addr 3
        //   11   : CHECKING addr 3 -> status=01 -> WRITING
        //   12   : WRITING addr 3 (scrub_correction=1, wr_en=1)
        //                           memory write latches at this posedge
        //   13   : READING addr 4
        // So we need to wait ~13 cycles from reset release before checking.
        // Wait 20 cycles to be safe.
        // ------------------------------------------------------------------
        @(posedge clock); #1;
        reset = 1'b0;
        $display("LOG: %0t : INFO  : tb_scrubber : reset released, scrubber running",
                 $time);

        // Monitor for scrub_correction pulse
        fork
            begin : monitor_correction
                logic saw_correction;
                saw_correction = 1'b0;
                repeat(30) begin
                    @(posedge clock); #1;
                    if (scrub_correction) begin
                        saw_correction = 1'b1;
                        $display("LOG: %0t : INFO  : tb_scrubber : scrub_correction pulsed", $time);
                        // Verify pulse is exactly 1 cycle
                        @(posedge clock); #1;
                        chk(int'(scrub_correction), 0, "scrub_correction cleared after 1 cycle");
                        disable monitor_correction;
                    end
                end
                if (!saw_correction) begin
                    $display("LOG: %0t : ERROR : tb_scrubber : scrub_correction never pulsed",
                             $time);
                    fail_count++;
                end
            end
        join

        // ------------------------------------------------------------------
        // Phase 4: Re-read CORRUPT_ADDR and verify the correction.
        // Issue read by waiting for scrub_rd_addr to be CORRUPT_ADDR again,
        // or simply do a direct verification read:
        // Present CORRUPT_ADDR to the memory read port for 1 cycle.
        // ------------------------------------------------------------------
        // The scrubber is now past addr 3 -- its rd_addr is driving higher
        // addresses. We wait for a full second pass to reach addr 3 again,
        // or we read the memory directly. Since we can check u_mem.mem[]
        // directly for the corrected codeword (no more single-bit error),
        // let's do a direct memory read via the rd port used by the scrubber.
        // Wait for the scrubber to reach addr 3 in the second pass.
        repeat(SCRUB_INTERVAL + 2*(CORRUPT_ADDR+1) + 4) @(posedge clock);
        #1;

        // At this point the scrubber has re-read addr 3 at least once.
        // Check that the stored word no longer reports an error by
        // briefly hijacking the rd port.  The scrubber is combinatorial on
        // rd_addr, so we just wait until scrub_rd_addr == CORRUPT_ADDR and
        // sample rd_error_status (which has 1-cycle latency, so we need to
        // find the cycle AFTER scrub_rd_addr was CORRUPT_ADDR).
        //
        // Simpler approach: check the stored raw word directly.
        // The original ECC-correct codeword should be restored.
        // We verify by triggering a direct read.
        begin
            // Force read of CORRUPT_ADDR for verification.
            // Since the memory rd_addr is driven by scrub_rd_addr (the
            // scrubber's current_addr), we use the cycle when the scrubber
            // naturally reads CORRUPT_ADDR. We already saw scrub_correction
            // fire once, meaning the write-back happened. Now verify status
            // via a read. Monitor the scrubber's next pass through addr 3:
            logic got_clean_read;
            got_clean_read = 1'b0;
            repeat(SCRUB_INTERVAL + 2*(MEM_DEPTH+1)) begin
                @(posedge clock); #1;
                // The cycle after scrub_rd_addr was CORRUPT_ADDR,
                // rd_data and rd_error_status are valid.
                // Since current_addr advances in CHECKING state,
                // check when scrubber is in CHECKING and current_addr==CORRUPT_ADDR.
                if (int'(dut.current_addr) == CORRUPT_ADDR &&
                    dut.state == 2'd2 /* CHECKING */) begin
                    chk(int'(scrub_rd_status), 0,
                        "re-read of CORRUPT_ADDR: rd_error_status=0 (no error)");
                    chk(signed'(scrub_rd_data), signed'(WRITE_VAL),
                        "re-read of CORRUPT_ADDR: rd_data = WRITE_VAL");
                    got_clean_read = 1'b1;
                    break;
                end
            end
            if (!got_clean_read) begin
                $display("LOG: %0t : ERROR : tb_scrubber : never observed clean re-read",
                         $time);
                fail_count++;
            end
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("scrubber: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end
        $finish;
    end

    initial begin
        $dumpfile("scrubber.fst");
        $dumpvars(0);
    end

endmodule : tb_scrubber
