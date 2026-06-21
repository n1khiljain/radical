// =============================================================================
// scrubber.sv
// ECC Scrubber FSM for weight_mem_ecc
//
// =============================================================================
// OPERATION
// =============================================================================
//
//   Walks memory addresses 0 .. MEM_DEPTH-1 one at a time, reading each word
//   through the ECC decoder.  When a single-bit correctable error is found
//   (rd_error_status == 2'b01), the ECC-corrected byte is written back in
//   place, refreshing the stored codeword.  A one-cycle scrub_correction
//   pulse fires on every such correction for telemetry.
//
//   After a complete pass, the scrubber idles for SCRUB_INTERVAL cycles
//   before starting the next pass.
//
// =============================================================================
// TIMING
// =============================================================================
//
//   Read path has 1-cycle latency (weight_mem_ecc synchronous capture).
//   Per-address cost:
//     - 1 cycle in READING  (rd_addr presented, data capturing)
//     - 1 cycle in CHECKING (rd_data valid, decision made)
//     - 1 cycle in WRITING  (wr_en asserted; memory latches at this posedge)
//       -- only paid when a correction is needed
//
//   Total pass duration (no errors): SCRUB_INTERVAL + 2 * MEM_DEPTH cycles
//
// =============================================================================
// PORT CONNECTIONS
// =============================================================================
//
//   Connect scrub_rd_addr / scrub_rd_data / scrub_rd_status to weight_mem_ecc
//   rd_addr / rd_data / rd_error_status.
//
//   Connect scrub_wr_en / scrub_wr_addr / scrub_wr_data to weight_mem_ecc
//   wr_en / wr_addr / wr_data (via a priority mux in top level if the
//   inference engine also uses the write port).
//
//   NOTE: do not connect to or edit accel_top.sv -- the integration agent
//   owns that file.
//
// =============================================================================

module scrubber #(
    parameter int ADDR_BITS     = 15,    // must match memory address width
    parameter int MEM_DEPTH     = 32768, // number of addresses to scrub per pass
    parameter int SCRUB_INTERVAL = 4096  // idle cycles between scrub passes
) (
    input  logic                    clock,
    input  logic                    reset,

    // Memory read port (connect to weight_mem_ecc rd_addr / rd_data / rd_error_status)
    output logic [ADDR_BITS-1:0]    scrub_rd_addr,
    input  logic signed [7:0]       scrub_rd_data,
    input  logic [1:0]              scrub_rd_status,

    // Memory write port (connect to weight_mem_ecc wr_en / wr_addr / wr_data)
    output logic                    scrub_wr_en,
    output logic [ADDR_BITS-1:0]    scrub_wr_addr,
    output logic signed [7:0]       scrub_wr_data,

    // Telemetry: 1-cycle pulse for each single-bit correction
    output logic                    scrub_correction
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    typedef enum logic [1:0] {
        IDLE     = 2'd0,  // waiting between passes
        READING  = 2'd1,  // rd_addr presented; waiting 1 cycle for data
        CHECKING = 2'd2,  // rd_data valid; decide if correction needed
        WRITING  = 2'd3   // write corrected byte back; pulse telemetry
    } state_t;

    state_t                   state;
    logic [ADDR_BITS-1:0]     current_addr;
    logic [31:0]              interval_cnt;     // down-counter between passes
    logic signed [7:0]        correction_data;  // latched ECC-corrected byte

    // =========================================================================
    // Continuous read address -- scrubber always drives rd_addr
    // =========================================================================
    assign scrub_rd_addr = current_addr;

    // =========================================================================
    // Combinational write-port outputs
    //
    // wr_en and scrub_correction are high for exactly one clock period
    // (while the FSM is in WRITING state).  The memory's synchronous write
    // latches the correction at the posedge that terminates WRITING state.
    // =========================================================================
    always_comb begin
        scrub_wr_en     = 1'b0;
        scrub_wr_addr   = current_addr;
        scrub_wr_data   = correction_data;
        scrub_correction = 1'b0;
        if (state == WRITING) begin
            scrub_wr_en      = 1'b1;
            scrub_correction = 1'b1;
        end
    end

    // =========================================================================
    // Registered FSM -- synchronous active-high reset
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            state           <= IDLE;
            current_addr    <= '0;
            interval_cnt    <= 32'(SCRUB_INTERVAL);
            correction_data <= 8'sh0;

        end else begin
            case (state)

                // -------------------------------------------------------------
                // IDLE: count down interval, then start a new scrub pass
                // -------------------------------------------------------------
                IDLE: begin
                    if (interval_cnt == 32'd0) begin
                        current_addr <= '0;
                        state        <= READING;
                    end else begin
                        interval_cnt <= interval_cnt - 1;
                    end
                end

                // -------------------------------------------------------------
                // READING: rd_addr is already driven to current_addr.
                // Spend one cycle for the memory's synchronous read latency.
                // -------------------------------------------------------------
                READING: begin
                    state <= CHECKING;
                end

                // -------------------------------------------------------------
                // CHECKING: rd_data and rd_error_status are valid.
                //   status 01 = single-bit correctable: go to WRITING
                //   anything else: advance to next address
                // -------------------------------------------------------------
                CHECKING: begin
                    if (scrub_rd_status == 2'b01) begin
                        // Latch ECC-corrected byte; write it back in WRITING
                        correction_data <= scrub_rd_data;
                        state           <= WRITING;
                    end else begin
                        // No correction needed; advance
                        if (current_addr == ADDR_BITS'(MEM_DEPTH - 1)) begin
                            interval_cnt <= 32'(SCRUB_INTERVAL);
                            state        <= IDLE;
                        end else begin
                            current_addr <= current_addr + 1'b1;
                            state        <= READING;
                        end
                    end
                end

                // -------------------------------------------------------------
                // WRITING: combinational outputs assert wr_en and scrub_correction
                // this cycle; the memory latches the correction at posedge clock.
                // Advance to the next address after the write.
                // -------------------------------------------------------------
                WRITING: begin
                    if (current_addr == ADDR_BITS'(MEM_DEPTH - 1)) begin
                        interval_cnt <= 32'(SCRUB_INTERVAL);
                        state        <= IDLE;
                    end else begin
                        current_addr <= current_addr + 1'b1;
                        state        <= READING;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule : scrubber
