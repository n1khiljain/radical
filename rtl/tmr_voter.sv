// =============================================================================
// tmr_voter.sv
// Triple Modular Redundancy (TMR) bitwise majority voter
//
// =============================================================================
// OPERATION
// =============================================================================
//
//   For each bit position k (0 .. WIDTH-1):
//     voted_out[k] = (in_a[k] & in_b[k]) | (in_a[k] & in_c[k]) | (in_b[k] & in_c[k])
//
//   This is a 2-of-3 majority function: the output follows whichever value
//   at least two of the three inputs agree on, masking a single-input fault.
//
//   disagreement is asserted (for exactly the affected bit positions) whenever
//   the three inputs are not unanimous.  It is a scalar OR of all bit-level
//   disagreements, providing a single-bit telemetry flag.
//
//   All outputs are combinational (no clock, no reset).
//
// =============================================================================

module tmr_voter #(
    parameter int WIDTH = 32
) (
    input  logic [WIDTH-1:0] in_a,
    input  logic [WIDTH-1:0] in_b,
    input  logic [WIDTH-1:0] in_c,
    output logic [WIDTH-1:0] voted_out,    // bitwise 2-of-3 majority
    output logic             disagreement  // 1 if any bit is not unanimous
);

    // =========================================================================
    // Bitwise majority vote
    // voted_out[k] = 1 iff at least two of {in_a[k], in_b[k], in_c[k]} are 1
    // =========================================================================
    assign voted_out = (in_a & in_b) | (in_a & in_c) | (in_b & in_c);

    // =========================================================================
    // Disagreement: any bit where the three inputs are not all equal
    // Per-bit: disagreement[k] = in_a[k]^in_b[k] | in_a[k]^in_c[k]
    // Scalar: OR-reduce across all bits
    // =========================================================================
    logic [WIDTH-1:0] bit_disagree;
    assign bit_disagree  = (in_a ^ in_b) | (in_a ^ in_c);
    assign disagreement  = |bit_disagree;

endmodule : tmr_voter
