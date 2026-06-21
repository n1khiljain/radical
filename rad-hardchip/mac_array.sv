// =============================================================================
// mac_array.sv
// 8x8 Systolic-style INT8 Multiply-Accumulate Array
//
// Description:
//   Implements 8 parallel dot-product units.  Each unit i computes:
//
//       result[i] = SUM_{j=0}^{7}  weights[i][j] * activations[j]
//
//   Multiplications and accumulations are combinational; results are captured
//   in a bank of output registers on the rising clock edge.
//
// Bit-width rationale:
//   - INT8 signed range : -128 .. +127
//   - Max product magnitude : 128 * 128 = 16 384  -> 16-bit signed product
//   - Max accumulated magnitude : 8 * 16 384 = 131 072
//     -> requires 17 magnitude bits -> 19-bit signed (1 sign + 18 magnitude)
//
// Ports:
//   clock        - system clock
//   reset        - synchronous active-high reset
//   weights      - 8x8 array of signed 8-bit weight values
//   activations  - 8-element signed 8-bit input activation vector
//   results      - 8-element signed 19-bit accumulated output vector
// =============================================================================

module mac_array (
    input  logic                    clock,
    input  logic                    reset,

    // Weight matrix: weights[row][col]
    input  logic signed [7:0]       weights     [0:7][0:7],

    // Input activation vector
    input  logic signed [7:0]       activations [0:7],

    // Accumulated output vector (19-bit signed to prevent overflow)
    output logic signed [18:0]      results     [0:7]
);

    // -------------------------------------------------------------------------
    // Internal combinational accumulation wires
    // -------------------------------------------------------------------------
    logic signed [18:0] acc_comb [0:7];

    // -------------------------------------------------------------------------
    // Combinational dot-product for each of the 8 output rows
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 8; i++) begin
            acc_comb[i] = 19'sd0;
            for (int j = 0; j < 8; j++) begin
                // Extend both operands to 19 bits before multiplying to keep
                // synthesis/linting clean; the product of two 8-bit signed
                // values fits in 16 bits, well within 19 bits.
                acc_comb[i] = acc_comb[i] +
                              (19'(signed'(weights[i][j])) *
                               19'(signed'(activations[j])));
            end
        end
    end

    // -------------------------------------------------------------------------
    // Output register bank — synchronous reset, captures combinational sums
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 8; i++) begin
                results[i] <= 19'sd0;
            end
        end else begin
            for (int i = 0; i < 8; i++) begin
                results[i] <= acc_comb[i];
            end
        end
    end

endmodule : mac_array
