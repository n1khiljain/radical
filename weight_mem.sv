// =============================================================================
// weight_mem.sv
// Synchronous SRAM — 64-entry × 8-bit signed (INT8) weight memory
//
// Description:
//   Simple single-port synchronous SRAM intended to hold the 8x8 weight
//   matrix for mac_array.  The flat address space maps the 8x8 matrix as:
//
//       addr = row * 8 + col   (0 .. 63)
//
//   Write behavior  : synchronous; data is written on the rising clock edge
//                     when wr_en is asserted.
//   Read behavior   : registered (one cycle of read latency); rd_data is
//                     updated on the rising clock edge following rd_addr.
//   Reset           : synchronous active-high reset clears only the rd_data
//                     output register.  SRAM array contents are not cleared
//                     (matches real SRAM semantics; software must initialise
//                     contents before use).
//
// Address width : 6 bits  (2^6 = 64 entries)
// Data width    : 8 bits signed (INT8)
//
// Read-during-write: if wr_en is asserted and wr_addr == rd_addr on the same
//   clock edge, the NEW (write) data is forwarded to rd_data (write-first).
// =============================================================================

module weight_mem (
    input  logic                clock,
    input  logic                reset,

    // Write port
    input  logic                wr_en,
    input  logic        [5:0]   wr_addr,
    input  logic signed [7:0]   wr_data,

    // Read port
    input  logic        [5:0]   rd_addr,
    output logic signed [7:0]   rd_data
);

    // -------------------------------------------------------------------------
    // Internal SRAM array
    // -------------------------------------------------------------------------
    logic signed [7:0] mem [0:63];

    // -------------------------------------------------------------------------
    // Synchronous write
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // -------------------------------------------------------------------------
    // Synchronous read with write-first forwarding
    // Reset clears the output register; array contents are undefined until
    // explicitly written.
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset) begin
            rd_data <= 8'sd0;
        end else begin
            // Write-first: forward new data when addresses collide
            if (wr_en && (wr_addr == rd_addr)) begin
                rd_data <= wr_data;
            end else begin
                rd_data <= mem[rd_addr];
            end
        end
    end

endmodule : weight_mem
