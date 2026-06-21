// =============================================================================
// telemetry_regs.sv
// Event-counter and event-FIFO register block for the rad-hard accelerator.
//
// =============================================================================
// REGISTER MAP
// =============================================================================
//
//   Offset  Access  Description
//   ------  ------  -----------------------------------------------------------
//   0x10    RO      scrub_corrections  — 32-bit free-running counter
//   0x14    RO      ecc_double_errors  — 32-bit free-running counter
//   0x18    RO      tmr_disagreements  — 32-bit free-running counter
//   0x1C    RO      inferences_total   — 32-bit free-running counter
//   0x30    RO/POP  event FIFO pop     — destructive read; returns oldest entry
//                                        or 32'h0 if FIFO is empty
//
// =============================================================================
// EVENT FIFO ENTRY BIT LAYOUT (32-bit)
// =============================================================================
//
//   [1:0]   event type  — 0=scrub_correct, 1=ecc_uncorrectable, 2=tmr_override
//   [17:2]  addr        — 16-bit memory address associated with the event
//   [31:18] timestamp   — 14-bit timestamp supplied by the caller
//
//   Packed as: {event_timestamp[13:0], event_addr[15:0], event_type[1:0]}
//
// =============================================================================
// INTERFACES
// =============================================================================
//
//   Counter increments
//     Each counter has a dedicated single-cycle high strobe input.
//     Counters saturate gracefully at 2^32-1 (wrap-around).
//
//   Event push
//     Assert event_push for one cycle while presenting event_type, event_addr,
//     and event_timestamp.  Pushes are silently dropped when the FIFO is full.
//
//   Register read
//     Present reg_addr and assert reg_rd_en for one cycle.
//     reg_rd_data is registered — valid the cycle after reg_rd_en is seen.
//     Reading offset 0x30 pops the FIFO (destructive); returns 0 when empty.
//
// =============================================================================

module telemetry_regs #(
    parameter int FIFO_DEPTH = 16    // must be a power of 2
) (
    input  logic        clock,
    input  logic        reset,

    // -------------------------------------------------------------------------
    // Counter increment pulses (single-cycle high strobe per event)
    // -------------------------------------------------------------------------
    input  logic        scrub_corrections_inc,
    input  logic        ecc_double_errors_inc,
    input  logic        tmr_disagreements_inc,
    input  logic        inferences_total_inc,

    // -------------------------------------------------------------------------
    // Event FIFO push interface
    // -------------------------------------------------------------------------
    input  logic        event_push,
    input  logic [1:0]  event_type,
    input  logic [15:0] event_addr,
    input  logic [13:0] event_timestamp,

    // -------------------------------------------------------------------------
    // Register read interface
    // -------------------------------------------------------------------------
    input  logic [7:0]  reg_addr,
    input  logic        reg_rd_en,
    output logic [31:0] reg_rd_data
);

    localparam int FIFO_PTR_W = $clog2(FIFO_DEPTH);

    // =========================================================================
    // Free-running event counters
    // Reset clears to 0; otherwise they increment and wrap freely.
    // =========================================================================
    logic [31:0] cnt_scrub;
    logic [31:0] cnt_ecc;
    logic [31:0] cnt_tmr;
    logic [31:0] cnt_infer;

    always_ff @(posedge clock) begin
        if (reset) begin
            cnt_scrub <= 32'h0;
            cnt_ecc   <= 32'h0;
            cnt_tmr   <= 32'h0;
            cnt_infer <= 32'h0;
        end else begin
            if (scrub_corrections_inc) cnt_scrub <= cnt_scrub + 32'h1;
            if (ecc_double_errors_inc) cnt_ecc   <= cnt_ecc   + 32'h1;
            if (tmr_disagreements_inc) cnt_tmr   <= cnt_tmr   + 32'h1;
            if (inferences_total_inc)  cnt_infer <= cnt_infer + 32'h1;
        end
    end

    // =========================================================================
    // Event FIFO — FIFO_DEPTH-deep × 32-bit circular buffer
    // =========================================================================
    logic [31:0]            fifo_mem   [0:FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0]  fifo_wr_ptr;
    logic [FIFO_PTR_W-1:0]  fifo_rd_ptr;
    logic [FIFO_PTR_W:0]    fifo_count;    // 0 .. FIFO_DEPTH

    // Status flags (combinational)
    logic fifo_empty;
    logic fifo_full;
    assign fifo_empty = (fifo_count == '0);
    assign fifo_full  =  fifo_count[FIFO_PTR_W];  // set when count == FIFO_DEPTH

    // Pop strobe: destructive read at 0x30 while FIFO non-empty
    logic fifo_pop;
    assign fifo_pop = reg_rd_en & (reg_addr == 8'h30) & ~fifo_empty;

    // Write path — pack and store entry, advance write pointer
    always_ff @(posedge clock) begin
        if (reset) begin
            fifo_wr_ptr <= '0;
        end else if (event_push && !fifo_full) begin
            fifo_mem[fifo_wr_ptr] <= {event_timestamp, event_addr, event_type};
            fifo_wr_ptr           <= fifo_wr_ptr + 1'b1;
        end
    end

    // Read path — advance read pointer on pop
    always_ff @(posedge clock) begin
        if (reset) begin
            fifo_rd_ptr <= '0;
        end else if (fifo_pop) begin
            fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
        end
    end

    // Occupancy counter — push, pop, simultaneous push+pop, or hold
    always_ff @(posedge clock) begin
        if (reset) begin
            fifo_count <= '0;
        end else begin
            case ({event_push && !fifo_full, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 1'b1;  // push only
                2'b01:   fifo_count <= fifo_count - 1'b1;  // pop  only
                default: fifo_count <= fifo_count;          // hold or simultaneous push+pop
            endcase
        end
    end

    // =========================================================================
    // Register read mux (registered output — valid one cycle after reg_rd_en)
    //
    // Pop behaviour: on the cycle reg_rd_en is sampled with addr=0x30:
    //   - reg_rd_data captures fifo_mem[fifo_rd_ptr]  (non-blocking, uses old ptr)
    //   - fifo_rd_ptr advances                         (non-blocking, same edge)
    //   Both assignments use the pre-edge values, so the correct head is returned.
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            reg_rd_data <= 32'h0;
        end else if (reg_rd_en) begin
            case (reg_addr)
                8'h10:   reg_rd_data <= cnt_scrub;
                8'h14:   reg_rd_data <= cnt_ecc;
                8'h18:   reg_rd_data <= cnt_tmr;
                8'h1C:   reg_rd_data <= cnt_infer;
                8'h30:   reg_rd_data <= fifo_empty ? 32'h0 : fifo_mem[fifo_rd_ptr];
                default: reg_rd_data <= 32'h0;
            endcase
        end
    end

endmodule : telemetry_regs
