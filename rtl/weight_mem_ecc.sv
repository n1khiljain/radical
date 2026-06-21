// =============================================================================
// weight_mem_ecc.sv
// ECC-protected weight SRAM — 32,768 entries × 8-bit signed data
//
// Storage layout:
//   Array depth  : 2^15 = 32,768 words  (15-bit address, covers the required
//                  26,698 valid addresses with clean power-of-2 headroom)
//   Word width   : 16 bits
//     [12: 0]  SECDED codeword (13-bit, from ecc_secded encoder)
//     [15:13]  Unused — always written as 0, ignored on read
//
// Write path (combinational encode + synchronous write):
//   wr_data [7:0] ──► ecc_secded encoder ──► codeword_out [12:0]
//   On posedge clock, wr_en=1 : mem[wr_addr] ← {3'b000, codeword_out}
//
// Read path (synchronous capture + combinational decode):
//   On posedge clock : rd_raw_reg ← mem[rd_addr]        (1-cycle latency)
//   Combinational   : ecc_secded decoder(rd_raw_reg[12:0])
//                     ──► rd_data [7:0]   (corrected 8-bit output)
//                     ──► rd_error_status [1:0]
//                           00 = no error
//                           01 = single-bit corrected transparently
//                           10 = double-bit uncorrectable
//
// Reset clears rd_raw_reg to 0 (decoder sees all-zeros codeword → rd_data=0).
// Memory array contents are NOT cleared on reset (real SRAM semantics).
//
// Latency: 1 clock cycle from rd_addr presented to rd_data valid
//          (identical to the original weight_mem)
//
// Shared ecc_secded instance: the encoder uses wr_data; the decoder uses
// rd_raw_reg[12:0].  Both are independent combinational paths inside
// ecc_secded, so they operate correctly in parallel without conflict.
// =============================================================================

module weight_mem_ecc (
    input  logic                clock,
    input  logic                reset,

    // Write port (host-facing)
    input  logic                wr_en,
    input  logic [14:0]         wr_addr,
    input  logic signed [7:0]   wr_data,

    // Read port
    input  logic [14:0]         rd_addr,
    output logic signed [7:0]   rd_data,
    output logic [1:0]          rd_error_status
);

    // -------------------------------------------------------------------------
    // Internal SRAM array — 32 K × 16-bit words
    // -------------------------------------------------------------------------
    logic [15:0] mem [0:32767];

    // -------------------------------------------------------------------------
    // ECC codec instantiation
    // Encoder : data_in   = wr_data    → codeword_out (stored on write)
    // Decoder : codeword_in = rd_raw_reg[12:0] → data_corrected, error_status
    // -------------------------------------------------------------------------
    logic [12:0] enc_codeword;   // encoder output (combinational from wr_data)
    logic [12:0] dec_codeword;   // decoder input  (from registered read word)
    logic [7:0]  dec_data;       // decoder data output
    logic [1:0]  dec_status;     // decoder error status
    logic [12:0] enc_unused_cw;  // unused encoder output on decoder side
    logic [7:0]  dec_unused_data; // unused decoder output on encoder side
    logic [1:0]  dec_unused_stat;

    ecc_secded u_ecc (
        // Encoder: driven by write-side data
        .data_in        (wr_data),
        .codeword_out   (enc_codeword),

        // Decoder: driven by registered read data
        .codeword_in    (dec_codeword),
        .data_corrected (dec_data),
        .error_status   (dec_status)
    );

    // -------------------------------------------------------------------------
    // Registered read word — synchronous capture with 1-cycle latency
    // -------------------------------------------------------------------------
    logic [15:0] rd_raw_reg;

    always_ff @(posedge clock) begin
        if (reset) begin
            rd_raw_reg <= 16'h0000;
        end else begin
            rd_raw_reg <= mem[rd_addr];
        end
    end

    // Feed registered codeword into the ECC decoder
    assign dec_codeword = rd_raw_reg[12:0];

    // -------------------------------------------------------------------------
    // Drive read outputs from ECC decoder (combinational from FF output)
    // -------------------------------------------------------------------------
    assign rd_data         = signed'(dec_data);
    assign rd_error_status = dec_status;

    // -------------------------------------------------------------------------
    // Synchronous write — encode then store
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (wr_en) begin
            mem[wr_addr] <= {3'b000, enc_codeword};
        end
    end

endmodule : weight_mem_ecc
