// =============================================================================
// tb_telemetry_regs.sv
// Testbench for telemetry_regs — event counters and event FIFO
//
// =============================================================================
// TEST PLAN
// =============================================================================
//
//  Phase 1 — FIFO push and ordered pop
//    Push 3 events with known type/addr/timestamp.
//    Pop all 3, verify each returned entry matches the push order (FIFO).
//    Expected entries (packed as {timestamp[13:0], addr[15:0], type[1:0]}):
//      e0: type=2'b01, addr=16'h0100, ts=14'h0020  → entry computed by TB
//      e1: type=2'b00, addr=16'h0200, ts=14'h0021  → entry computed by TB
//      e2: type=2'b10, addr=16'h0300, ts=14'h0022  → entry computed by TB
//
//  Phase 2 — Empty FIFO returns 0
//    After Phase 1 drains the FIFO, one more pop must return 32'h0.
//
//  Phase 3 — Counter increments and readback
//    Pulse each counter a known number of times, then read back via register
//    interface and verify exact values:
//      scrub_corrections: 5  pulses → expect 5   at 0x10
//      ecc_double_errors: 3  pulses → expect 3   at 0x14
//      tmr_disagreements: 7  pulses → expect 7   at 0x18
//      inferences_total:  4  pulses → expect 4   at 0x1C
//
// =============================================================================
// TIMING MODEL
// =============================================================================
//
//   reg_rd_data is registered — the sequence for a single register read is:
//     1. Set reg_addr and reg_rd_en = 1 before the posedge
//     2. posedge: reg_rd_data captures the register value
//     3. #1 (1ps): nonblocking assignments have resolved → sample reg_rd_data
//     4. Deassert reg_rd_en
//
//   Reading 0x30 is destructive: fifo_rd_ptr advances on the same posedge that
//   captures the head entry into reg_rd_data (both non-blocking).
//
// =============================================================================

module tb_telemetry_regs;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clock;
    logic        reset;

    logic        scrub_corrections_inc;
    logic        ecc_double_errors_inc;
    logic        tmr_disagreements_inc;
    logic        inferences_total_inc;

    logic        event_push;
    logic [1:0]  event_type;
    logic [15:0] event_addr;
    logic [13:0] event_timestamp;

    logic [7:0]  reg_addr;
    logic        reg_rd_en;
    logic [31:0] reg_rd_data;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    telemetry_regs #(
        .FIFO_DEPTH(16)
    ) dut (
        .clock                (clock),
        .reset                (reset),
        .scrub_corrections_inc(scrub_corrections_inc),
        .ecc_double_errors_inc(ecc_double_errors_inc),
        .tmr_disagreements_inc(tmr_disagreements_inc),
        .inferences_total_inc (inferences_total_inc),
        .event_push           (event_push),
        .event_type           (event_type),
        .event_addr           (event_addr),
        .event_timestamp      (event_timestamp),
        .reg_addr             (reg_addr),
        .reg_rd_en            (reg_rd_en),
        .reg_rd_data          (reg_rd_data)
    );

    // -------------------------------------------------------------------------
    // Clock generator — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 0;
    always  #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Check utility
    // -------------------------------------------------------------------------
    integer fail_count;

    task automatic check(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       msg
    );
        if (actual !== expected) begin
            $display("LOG: %0t : ERROR : tb_telemetry_regs : %s : expected=0x%08X actual=0x%08X",
                     $time, msg, expected, actual);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_telemetry_regs : %s : value=0x%08X  OK",
                     $time, msg, actual);
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("TEST START");
        fail_count = 0;

        // Initialise all inputs
        reset                  = 1'b1;
        scrub_corrections_inc  = 1'b0;
        ecc_double_errors_inc  = 1'b0;
        tmr_disagreements_inc  = 1'b0;
        inferences_total_inc   = 1'b0;
        event_push             = 1'b0;
        event_type             = 2'b00;
        event_addr             = 16'h0;
        event_timestamp        = 14'h0;
        reg_addr               = 8'h0;
        reg_rd_en              = 1'b0;

        // Hold reset for 3 cycles then release
        repeat(3) @(posedge clock);
        #1; reset = 1'b0;

        // ==================================================================
        // Phase 1 — Push 3 events
        //
        //   e0: type=2'b01 (ecc_uncorrectable), addr=0x0100, ts=0x0020
        //   e1: type=2'b00 (scrub_correct),     addr=0x0200, ts=0x0021
        //   e2: type=2'b10 (tmr_override),       addr=0x0300, ts=0x0022
        // ==================================================================
        $display("--- Phase 1: push 3 events ---");

        // Push e0
        event_push      = 1'b1;
        event_type      = 2'b01;
        event_addr      = 16'h0100;
        event_timestamp = 14'h0020;
        @(posedge clock); #1;

        // Push e1
        event_type      = 2'b00;
        event_addr      = 16'h0200;
        event_timestamp = 14'h0021;
        @(posedge clock); #1;

        // Push e2
        event_type      = 2'b10;
        event_addr      = 16'h0300;
        event_timestamp = 14'h0022;
        @(posedge clock); #1;

        // Deassert push
        event_push = 1'b0;
        @(posedge clock); #1;

        // ==================================================================
        // Pop e0 — must match first-pushed entry
        // ==================================================================
        $display("--- Phase 1: pop 3 events (FIFO order) ---");

        reg_addr  = 8'h30;
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data,
              {14'h0020, 16'h0100, 2'b01},
              "pop[0] e0: type=01 addr=0100 ts=0020");

        // Pop e1
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data,
              {14'h0021, 16'h0200, 2'b00},
              "pop[1] e1: type=00 addr=0200 ts=0021");

        // Pop e2
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data,
              {14'h0022, 16'h0300, 2'b10},
              "pop[2] e2: type=10 addr=0300 ts=0022");

        // ==================================================================
        // Phase 2 — FIFO is now empty: pop must return 0
        // ==================================================================
        $display("--- Phase 2: pop from empty FIFO (expect 0) ---");

        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data, 32'h0, "empty FIFO pop returns 0");

        // ==================================================================
        // Phase 3 — Counter increments and readback
        //
        //   scrub_corrections: 5 pulses → 0x10 must return 32'd5
        //   ecc_double_errors: 3 pulses → 0x14 must return 32'd3
        //   tmr_disagreements: 7 pulses → 0x18 must return 32'd7
        //   inferences_total:  4 pulses → 0x1C must return 32'd4
        // ==================================================================
        $display("--- Phase 3: counter increments ---");

        // 5 scrub_corrections pulses
        repeat(5) begin
            scrub_corrections_inc = 1'b1;
            @(posedge clock); #1;
            scrub_corrections_inc = 1'b0;
        end

        // 3 ecc_double_errors pulses
        repeat(3) begin
            ecc_double_errors_inc = 1'b1;
            @(posedge clock); #1;
            ecc_double_errors_inc = 1'b0;
        end

        // 7 tmr_disagreements pulses
        repeat(7) begin
            tmr_disagreements_inc = 1'b1;
            @(posedge clock); #1;
            tmr_disagreements_inc = 1'b0;
        end

        // 4 inferences_total pulses
        repeat(4) begin
            inferences_total_inc = 1'b1;
            @(posedge clock); #1;
            inferences_total_inc = 1'b0;
        end

        $display("--- Phase 3: read back counters ---");

        // Read scrub_corrections (0x10) — expect 5
        reg_addr  = 8'h10;
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data, 32'd5, "scrub_corrections @ 0x10 = 5");

        // Read ecc_double_errors (0x14) — expect 3
        reg_addr  = 8'h14;
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data, 32'd3, "ecc_double_errors @ 0x14 = 3");

        // Read tmr_disagreements (0x18) — expect 7
        reg_addr  = 8'h18;
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data, 32'd7, "tmr_disagreements @ 0x18 = 7");

        // Read inferences_total (0x1C) — expect 4
        reg_addr  = 8'h1C;
        reg_rd_en = 1'b1;
        @(posedge clock); #1;
        reg_rd_en = 1'b0;
        check(reg_rd_data, 32'd4, "inferences_total  @ 0x1C = 4");

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("telemetry_regs: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("telemetry_regs.fst");
        $dumpvars(0);
    end

endmodule : tb_telemetry_regs
