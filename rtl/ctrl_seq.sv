// =============================================================================
// ctrl_seq.sv
// Inference sequencer FSM for the MNIST accelerator pipeline.
//
// =============================================================================
// PIPELINE OVERVIEW (all compute stages are fully combinational)
// =============================================================================
//
//   INPUT      STAGE       BUFFER        NEXT INPUT
//   --------   ---------   -----------   ----------
//   image_in → conv1_stage → conv1_buf → conv2_stage
//                          (19→32 sign-ext)
//   conv1_buf  → conv2_stage → conv2_buf → fc1_stage (via flatten)
//   conv2_buf  → [flatten]  → flat_conv2
//   flat_conv2 → fc1_stage  → fc1_buf   → fc2_stage
//   fc1_buf    → fc2_stage  → fc2_buf   → argmax + logits out
//
// =============================================================================
// FSM STATE SEQUENCE
// =============================================================================
//
//   IDLE      — wait for start pulse; latch image_in into image_buf
//   RUN_CONV1 — conv1 output is combinatorially valid; latch conv1_buf
//   RUN_CONV2 — conv2 output is combinatorially valid; latch conv2_buf
//   RUN_FC1   — fc1  output is combinatorially valid; latch fc1_buf
//   RUN_FC2   — fc2  output is combinatorially valid; latch fc2_buf + logits
//   ARGMAX    — argmax_comb is valid (from fc2_buf); register predicted_class
//   DONE      — pulse done=1, clear busy, return to IDLE
//
//   Each state occupies exactly one clock cycle (stages are combinational).
//   Total latency: 7 cycles from start to done (inclusive).
//
// =============================================================================
// FLATTEN MAPPING  (conv2_buf → flat_conv2 → fc1 input)
// =============================================================================
//
//   conv2_buf is shaped [16 channels][7 rows][7 cols].
//   fc1 expects a flat 784-element vector.
//
//   Channel-first row-major order (identical to PyTorch nn.Flatten()):
//     flat_conv2[ch*49 + r*7 + c]  =  conv2_buf[ch][r][c]
//
//   Index walk:
//     ch=0, r=0, c=0  →  flat[  0]      (channel 0, row 0, col 0)
//     ch=0, r=0, c=6  →  flat[  6]      (channel 0, row 0, col 6)
//     ch=0, r=1, c=0  →  flat[  7]      (channel 0, row 1, col 0)
//     ch=0, r=6, c=6  →  flat[ 48]      (channel 0, last pixel)
//     ch=1, r=0, c=0  →  flat[ 49]      (channel 1, first pixel)
//     ch=15,r=6, c=6  →  flat[783]      (channel 15, last pixel)
//
// =============================================================================
// SIGN-EXTENSION  (conv1 output 19-bit → conv1_buf 32-bit)
// =============================================================================
//
//   conv1_stage outputs logic signed [18:0].
//   conv2_stage expects logic signed [31:0].
//   Explicit sign extension: {13{bit[18]}, conv1_out[18:0]}.
//
// =============================================================================

module ctrl_seq (
    input  logic        clock,
    input  logic        reset,

    // Control interface
    input  logic        start,              // one-cycle pulse to begin inference
    output logic        busy,               // high throughout inference
    output logic        done,               // one-cycle pulse when fc2 output valid

    // Input image: 28×28 = 784 pixels, unsigned 8-bit, row-major flat
    input  logic [7:0]  image_in [0:783],

    // Weights: conv1  [out_ch=8][kr][kc]
    input  logic signed [7:0]  conv1_w [0:7][0:2][0:2],

    // Weights: conv2  [out_ch=16][in_ch=8][kr][kc]
    input  logic signed [7:0]  conv2_w [0:15][0:7][0:2][0:2],

    // Weights + biases: fc1  [out=32][in=784]
    input  logic signed [7:0]  fc1_w [0:31][0:783],
    input  logic signed [31:0] fc1_b [0:31],

    // Weights + biases: fc2  [out=10][in=32]
    input  logic signed [7:0]  fc2_w [0:9][0:31],
    input  logic signed [31:0] fc2_b [0:9],

    // Inference outputs
    output logic signed [31:0] logits          [0:9],  // fc2 raw scores
    output logic [3:0]         predicted_class         // argmax index (0-9)
);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        RUN_CONV1 = 3'd1,
        RUN_CONV2 = 3'd2,
        RUN_FC1   = 3'd3,   // launch fc1 (pulse start)
        WAIT_FC1  = 3'd7,   // stall until fc1's multi-cycle dot product finishes
        RUN_FC2   = 3'd4,
        ARGMAX    = 3'd5,
        DONE      = 3'd6
    } state_t;

    state_t state;

    // =========================================================================
    // Registered intermediate activation buffers
    // (populated by the FSM in each RUN_xxx state)
    // =========================================================================
    logic [7:0]          image_buf [0:783];           // latched input image
    logic signed [31:0]  conv1_buf [0:7][0:13][0:13]; // conv1 out (sign-ext 19→32)
    logic signed [31:0]  conv2_buf [0:15][0:6][0:6];  // conv2 out
    logic signed [31:0]  fc1_buf   [0:31];             // fc1 out
    logic signed [31:0]  fc2_buf   [0:9];              // fc2 out (argmax input)

    // =========================================================================
    // Combinational: reshape image_buf [784] → conv1_pixel [28][28]
    // Mapping: image_buf[r*28 + c] → conv1_pixel[r][c]
    // =========================================================================
    logic signed [7:0] conv1_pixel [0:27][0:27];
    always_comb begin
        for (int r = 0; r < 28; r++)
            for (int c = 0; c < 28; c++)
                conv1_pixel[r][c] = signed'(image_buf[r*28 + c]);
    end

    // =========================================================================
    // conv1_stage instance  (28×28 → 8ch 14×14, fully combinational)
    // =========================================================================
    logic signed [18:0] conv1_out [0:7][0:13][0:13];

    conv1_stage #(.IN_ROWS(28), .IN_COLS(28), .OUT_CH(8)) u_conv1 (
        .pixel_in   (conv1_pixel),
        .kernel_w   (conv1_w),
        .feature_out(conv1_out)
    );

    // Combinational sign-extension: conv1_out [18:0] → conv1_out32 [31:0]
    // Explicit: {13{sign_bit}, value[18:0]}
    logic signed [31:0] conv1_out32 [0:7][0:13][0:13];
    always_comb begin
        for (int ch = 0; ch < 8; ch++)
            for (int r = 0; r < 14; r++)
                for (int c = 0; c < 14; c++)
                    conv1_out32[ch][r][c] = {{13{conv1_out[ch][r][c][18]}},
                                              conv1_out[ch][r][c]};
    end

    // =========================================================================
    // conv2_stage instance  (8ch 14×14 → 16ch 7×7, fully combinational)
    // Wired to conv1_buf (registered output of the previous layer)
    // =========================================================================
    logic signed [31:0] conv2_out [0:15][0:6][0:6];

    conv2_stage #(.IN_CH(8), .IN_ROWS(14), .IN_COLS(14), .OUT_CH(16)) u_conv2 (
        .act_in     (conv1_buf),
        .kernel_w   (conv2_w),
        .feature_out(conv2_out)
    );

    // =========================================================================
    // Combinational flatten: conv2_buf [16][7][7] → flat_conv2 [784]
    //
    // Channel-first row-major order — matches PyTorch nn.Flatten(start_dim=1):
    //   flat_conv2[ch*49 + r*7 + c] = conv2_buf[ch][r][c]
    //
    // The 49-stride between channels (= 7×7) and 7-stride between rows
    // ensure that when the Python model exports weights for fc1, the weight
    // index mapping is consistent with this hardware flattening.
    // =========================================================================
    logic signed [31:0] flat_conv2 [0:783];
    always_comb begin
        for (int ch = 0; ch < 16; ch++)
            for (int r = 0; r < 7; r++)
                for (int c = 0; c < 7; c++)
                    flat_conv2[ch*49 + r*7 + c] = conv2_buf[ch][r][c];
    end

    // =========================================================================
    // fc1_stage instance  (784→32, dot-product + bias + ReLU)
    // NOW MULTI-CYCLE: driven by start/busy/done handshake (see RUN_FC1/WAIT_FC1).
    // Wired to flat_conv2 (flattened registered conv2 output), held stable for
    // the whole run.
    // =========================================================================
    logic signed [31:0] fc1_out [0:31];
    logic               fc1_start;   // FSM-driven one-cycle launch pulse
    logic               fc1_busy;    // (observability; unused by the FSM)
    logic               fc1_done;    // asserts when fc1_out is valid

    fc1_stage #(.IN_SIZE(784), .OUT_SIZE(32)) u_fc1 (
        .clock  (clock),
        .reset  (reset),
        .start  (fc1_start),
        .busy   (fc1_busy),
        .done   (fc1_done),
        .act_in (flat_conv2),
        .weights(fc1_w),
        .bias   (fc1_b),
        .act_out(fc1_out)
    );

    // =========================================================================
    // fc2_stage instance  (32→10, dot-product + bias, NO ReLU, combinational)
    // Wired to fc1_buf (registered fc1 output)
    // =========================================================================
    logic signed [31:0] fc2_out [0:9];

    fc2_stage #(.IN_SIZE(32), .OUT_SIZE(10)) u_fc2 (
        .act_in (fc1_buf),
        .weights(fc2_w),
        .bias   (fc2_b),
        .act_out(fc2_out)
    );

    // =========================================================================
    // Combinational argmax over fc2_buf (10 classes, index 0–9)
    // Runs continuously; result registered into predicted_class in ARGMAX state.
    // =========================================================================
    logic signed [31:0] argmax_max;
    logic [3:0]         argmax_comb;
    always_comb begin
        argmax_max  = fc2_buf[0];
        argmax_comb = 4'd0;
        for (int i = 1; i < 10; i++) begin
            if (fc2_buf[i] > argmax_max) begin
                argmax_max  = fc2_buf[i];
                argmax_comb = 4'(i);
            end
        end
    end

    // =========================================================================
    // Registered FSM — synchronous active-high reset
    // =========================================================================
    always_ff @(posedge clock) begin
        if (reset) begin
            state           <= IDLE;
            busy            <= 1'b0;
            done            <= 1'b0;
            fc1_start       <= 1'b0;
            predicted_class <= 4'd0;
            for (int i = 0; i < 10; i++) logits[i] <= 32'sh0;
        end else begin
            done      <= 1'b0;   // default: clear done pulse every cycle
            fc1_start <= 1'b0;   // default: fc1 launch is a one-cycle pulse

            case (state)

                // -----------------------------------------------------------------
                IDLE: begin
                    if (start) begin
                        state <= RUN_CONV1;
                        busy  <= 1'b1;
                        // Latch the input image — conv1 will compute from this
                        // on the very next cycle (state = RUN_CONV1)
                        for (int i = 0; i < 784; i++)
                            image_buf[i] <= image_in[i];
                    end
                end

                // -----------------------------------------------------------------
                // conv1 is combinatorially computing from conv1_pixel (← image_buf).
                // image_buf was just loaded at the previous posedge; result is ready.
                // Capture and sign-extend 19-bit output to 32-bit conv1_buf.
                RUN_CONV1: begin
                    state <= RUN_CONV2;
                    for (int ch = 0; ch < 8; ch++)
                        for (int r = 0; r < 14; r++)
                            for (int c = 0; c < 14; c++)
                                conv1_buf[ch][r][c] <= conv1_out32[ch][r][c];
                end

                // -----------------------------------------------------------------
                // conv2 is computing from conv1_buf. Capture conv2 output.
                RUN_CONV2: begin
                    state <= RUN_FC1;
                    for (int ch = 0; ch < 16; ch++)
                        for (int r = 0; r < 7; r++)
                            for (int c = 0; c < 7; c++)
                                conv2_buf[ch][r][c] <= conv2_out[ch][r][c];
                end

                // -----------------------------------------------------------------
                // fc1 is now MULTI-CYCLE. flat_conv2 (← conv2_buf, registered) is
                // stable here. Pulse fc1's start and stall in WAIT_FC1 until done.
                RUN_FC1: begin
                    fc1_start <= 1'b1;     // launch fc1 (sampled at the next edge)
                    state     <= WAIT_FC1;
                end

                // -----------------------------------------------------------------
                // Hold while fc1 accumulates (IN_SIZE+2 cycles). fc1's inputs
                // (flat_conv2, fc1_w, fc1_b) stay stable throughout. On fc1_done,
                // fc1_out (= act_out) is valid — capture it and advance.
                WAIT_FC1: begin
                    if (fc1_done) begin
                        for (int i = 0; i < 32; i++)
                            fc1_buf[i] <= fc1_out[i];
                        state <= RUN_FC2;
                    end
                end

                // -----------------------------------------------------------------
                // fc2 is computing from fc1_buf. Capture fc2 output into both
                // fc2_buf (for argmax) and logits (for the output port).
                RUN_FC2: begin
                    state <= ARGMAX;
                    for (int i = 0; i < 10; i++) begin
                        fc2_buf[i] <= fc2_out[i];
                        logits[i]  <= fc2_out[i];
                    end
                end

                // -----------------------------------------------------------------
                // argmax_comb is valid (computed from fc2_buf just loaded last cycle).
                // Register the winning class index.
                ARGMAX: begin
                    state           <= DONE;
                    predicted_class <= argmax_comb;
                end

                // -----------------------------------------------------------------
                // Pulse done, clear busy, return to IDLE.
                DONE: begin
                    state <= IDLE;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule : ctrl_seq
