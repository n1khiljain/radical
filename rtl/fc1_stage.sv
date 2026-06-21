// =============================================================================
// fc1_stage.sv
// Fully-connected layer 1: IN_SIZE inputs → OUT_SIZE outputs + ReLU
//
// PIPELINED / MULTI-CYCLE VERSION (integration-wip)
// -----------------------------------------------------------------------------
// Previously this layer computed all OUT_SIZE × IN_SIZE (= 32 × 784 = 25,088)
// multiply-accumulates in one combinational cloud. Even split per-neuron with a
// generate loop, that made iverilog elaboration take many minutes inside chip.sv.
//
// This version sequences the dot product over IN_SIZE clock cycles. On each
// cycle it broadcasts ONE input element act_in[idx] to all OUT_SIZE neurons and
// each neuron does a single MAC into its own accumulator. The per-cycle
// combinational cloud is therefore only OUT_SIZE multiply-adds (32), and no
// IN_SIZE-deep loop is unrolled at compile time → fast to compile.
//
// =============================================================================
// MATH (identical to the old combinational version)
// =============================================================================
//   For each output neuron o:
//     dot_acc[o]  = Σ_{i=0}^{IN_SIZE-1}  act_in[i] × weights[o][i]   (64-bit)
//     pre_relu[o] = dot_acc[o] + sign_extend(bias[o])                (64-bit)
//     act_out[o]  = max(0, pre_relu[o])[31:0]                        (32-bit)
//
// =============================================================================
// HANDSHAKE  (NEW — ctrl_seq must be updated to drive this; see notes below)
// =============================================================================
//   start : single-cycle pulse. Latches the current act_in/weights/bias and
//           begins accumulation. Ignored unless idle.
//   busy  : high from the cycle after start until done.
//   done  : single-cycle pulse asserted when act_out / dot_acc / pre_relu are
//           valid. Outputs then hold until the next run.
//
//   Latency: IN_SIZE + 2 cycles from start pulse to done pulse
//            (1 cycle launch + IN_SIZE accumulate cycles + 1 finish cycle).
//            For IN_SIZE=784 that is 786 cycles.
//
//   act_in / weights / bias must be held stable from the start pulse through
//   done (the design reads act_in[idx]/weights[o][idx] each cycle; it does not
//   snapshot them into internal registers).
//
// =============================================================================
// SIZING RATIONALE  (unchanged)
// =============================================================================
//   act_in 32-bit signed × weight INT8 → product needs 39 bits + sign.
//   Accumulated over IN_SIZE=784 → ~2^48 → 64-bit signed accumulator is ample.
//   Output truncated to 32-bit after ReLU; bias add done at 64-bit precision.
//
// Default parameters match the real FC1 shape (flattened conv2 = 16×7×7):
//   IN_SIZE=784, OUT_SIZE=32
// =============================================================================

module fc1_stage #(
    parameter int IN_SIZE  = 784,
    parameter int OUT_SIZE = 32
) (
    input  logic               clock,
    input  logic               reset,        // synchronous active-high

    input  logic               start,        // pulse to begin a dot-product run
    output logic               busy,          // high during accumulation
    output logic               done,          // pulse when outputs are valid

    input  logic signed [31:0] act_in  [0:IN_SIZE-1],
    input  logic signed [7:0]  weights [0:OUT_SIZE-1][0:IN_SIZE-1],
    input  logic signed [31:0] bias    [0:OUT_SIZE-1],
    output logic signed [31:0] act_out [0:OUT_SIZE-1]
);

    // Index wide enough to hold 0 .. IN_SIZE (one bit of headroom past IN_SIZE-1)
    localparam int IDX_W = $clog2(IN_SIZE) + 1;

    // =========================================================================
    // Live accumulators + observable result arrays
    // dot_acc[] / pre_relu[] are module-level and latched in FINISH so existing
    // testbench hierarchical references (dut.dot_acc[o], dut.pre_relu[o]) work.
    // =========================================================================
    logic signed [63:0] acc      [0:OUT_SIZE-1];   // running accumulators
    logic signed [63:0] dot_acc  [0:OUT_SIZE-1];   // raw dot product (latched)
    logic signed [63:0] pre_relu [0:OUT_SIZE-1];   // post-bias, pre-ReLU (latched)

    logic [IDX_W-1:0] idx;

    typedef enum logic [1:0] {
        IDLE   = 2'd0,
        ACCUM  = 2'd1,
        FINISH = 2'd2
    } state_t;
    state_t state;

    // =========================================================================
    // Sequencing FSM
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            state <= IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
            idx   <= '0;
            for (int o = 0; o < OUT_SIZE; o++) begin
                acc[o]      <= 64'sd0;
                dot_acc[o]  <= 64'sd0;
                pre_relu[o] <= 64'sd0;
                act_out[o]  <= 32'sd0;
            end
        end else begin
            done <= 1'b0;   // default: done is a one-cycle pulse

            case (state)
                // -----------------------------------------------------------
                IDLE: begin
                    if (start) begin
                        idx  <= '0;
                        busy <= 1'b1;
                        for (int o = 0; o < OUT_SIZE; o++)
                            acc[o] <= 64'sd0;
                        state <= ACCUM;
                    end
                end

                // -----------------------------------------------------------
                // One input element per cycle, MAC'd into all OUT_SIZE neurons.
                // Per-cycle combinational cloud = OUT_SIZE multiply-adds only.
                // -----------------------------------------------------------
                ACCUM: begin
                    for (int o = 0; o < OUT_SIZE; o++)
                        acc[o] <= acc[o] +
                                  64'(signed'(act_in[idx])) *
                                  64'(signed'(weights[o][idx]));

                    if (idx == IDX_W'(IN_SIZE - 1))
                        state <= FINISH;
                    else
                        idx <= idx + 1'b1;
                end

                // -----------------------------------------------------------
                // Bias add + ReLU + truncation; latch observable outputs.
                // acc[] already holds the full IN_SIZE-term sum at this point.
                // -----------------------------------------------------------
                FINISH: begin
                    for (int o = 0; o < OUT_SIZE; o++) begin
                        logic signed [63:0] prv;
                        prv = acc[o] + 64'(signed'(bias[o]));
                        dot_acc[o]  <= acc[o];
                        pre_relu[o] <= prv;
                        act_out[o]  <= prv[63] ? 32'sd0 : prv[31:0];
                    end
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule : fc1_stage
