// =============================================================================
// mac_tmr.sv
// Triple Modular Redundancy wrapper for mac_array
//
// =============================================================================
// OPERATION
// =============================================================================
//
//   When HARDENING_EN=1 (default):
//     Three identical mac_array instances (u_mac_a, u_mac_b, u_mac_c) receive
//     the same weights and activations.  Their 19-bit result vectors are
//     voted bitwise by a tmr_voter instance on each output lane.
//
//     Any single-instance upset is masked by the majority vote.  A scalar
//     disagreement output fires whenever the three copies disagree on any
//     bit of any lane, providing a telemetry signal for SEU logging.
//
//   When HARDENING_EN=0:
//     Only u_mac_a is instantiated (lower area / power for non-rad-hard builds).
//     results and disagreement are driven directly from u_mac_a.results.
//     disagreement is tied to 0.
//
// =============================================================================
// PORT MAP
// =============================================================================
//
//   Clock/reset and mac_array weight/activation inputs are identical to
//   mac_array.  The only additions are:
//     disagreement -- 1 if any voter saw a non-unanimous triple
//
//   NOTE: do not edit accel_top.sv -- the integration agent owns that file.
//   Hand this module off as a standalone component for the integration agent
//   to wire into the top level.
//
// =============================================================================

module mac_tmr #(
    parameter int HARDENING_EN = 1  // 1: TMR active; 0: single mac_array passthrough
) (
    input  logic                clock,
    input  logic                reset,

    input  logic signed [7:0]   weights     [0:7][0:7],
    input  logic signed [7:0]   activations [0:7],

    output logic signed [18:0]  results     [0:7],   // voted (or passthrough) output
    output logic                disagreement          // TMR fault flag (0 when HARDENING_EN=0)
);

    generate
        if (HARDENING_EN) begin : g_tmr

            // -----------------------------------------------------------------
            // Three mac_array instances driven with identical inputs
            // -----------------------------------------------------------------
            logic signed [18:0] res_a [0:7];
            logic signed [18:0] res_b [0:7];
            logic signed [18:0] res_c [0:7];

            mac_array u_mac_a (
                .clock      (clock),
                .reset      (reset),
                .weights    (weights),
                .activations(activations),
                .results    (res_a)
            );
            mac_array u_mac_b (
                .clock      (clock),
                .reset      (reset),
                .weights    (weights),
                .activations(activations),
                .results    (res_b)
            );
            mac_array u_mac_c (
                .clock      (clock),
                .reset      (reset),
                .weights    (weights),
                .activations(activations),
                .results    (res_c)
            );

            // -----------------------------------------------------------------
            // Per-lane majority voter (one tmr_voter per output lane)
            // Each voter handles one 19-bit result element.
            // -----------------------------------------------------------------
            logic lane_disagree [0:7];

            for (genvar lane = 0; lane < 8; lane++) begin : g_voter
                logic [18:0] voted_lane;
                logic        lane_dis;

                tmr_voter #(.WIDTH(19)) u_voter (
                    .in_a        (19'(res_a[lane])),
                    .in_b        (19'(res_b[lane])),
                    .in_c        (19'(res_c[lane])),
                    .voted_out   (voted_lane),
                    .disagreement(lane_dis)
                );

                assign results[lane]      = signed'(voted_lane);
                assign lane_disagree[lane] = lane_dis;
            end

            // Aggregate disagreement: any lane disagreement -> flag
            assign disagreement = |{lane_disagree[0], lane_disagree[1],
                                    lane_disagree[2], lane_disagree[3],
                                    lane_disagree[4], lane_disagree[5],
                                    lane_disagree[6], lane_disagree[7]};

        end else begin : g_passthrough

            // -----------------------------------------------------------------
            // Single mac_array -- no TMR overhead
            // -----------------------------------------------------------------
            mac_array u_mac_a (
                .clock      (clock),
                .reset      (reset),
                .weights    (weights),
                .activations(activations),
                .results    (results)
            );

            assign disagreement = 1'b0;

        end
    endgenerate

endmodule : mac_tmr
