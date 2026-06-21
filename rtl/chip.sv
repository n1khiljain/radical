// =============================================================================
// chip.sv  —  top-level AXI-lite + AXI-stream wrapper for the MNIST accelerator
// =============================================================================
//
// REGISTER MAP  (offsets from chip base; host prepends 0x4000_0000)
//   0x00  CTRL        WO   [2]=harden_en  [1]=scrub_en  [0]=start_infer (pulse)
//   0x04  STATUS      RO   [1]=done (latched until next start)  [0]=busy
//   0x10  SCRUB_CORR  RO   free-running 32-bit counter
//   0x14  ECC_DERR    RO   free-running 32-bit counter
//   0x18  TMR_DISAG   RO   free-running 32-bit counter
//   0x1C  INFER_TOTAL RO   free-running 32-bit counter
//   0x20  LAST_OUTPUT RO   [3:0] = predicted class (0-9)
//   0x30  EVENT_POP   RO   destructive FIFO pop; returns 0 if empty
//
// AXI-STREAM PROTOCOL  (single byte-wide stream, tdata[7:0])
//   Phase 1 — Weight load:  host streams weights.bin (26 730 bytes).
//             4-byte length-prefix headers and unused conv biases are consumed
//             and discarded.  Weight / fc-bias bytes go to internal registers.
//   Phase 2 — Image input:  host streams 784 bytes (28x28 uint8 row-major),
//             tlast asserted on byte 783.
//   Phase 3 — Start:        host writes CTRL[0]=1.  busy asserts; ctrl_seq
//             runs for 7 cycles; done latches; LAST_OUTPUT updates.
//   Phase 4 — Repeat from Phase 2 for the next image.
//
// Note: conv1_b / conv2_b are consumed from the stream but not forwarded to
//       ctrl_seq (the conv stages have no bias ports in this implementation).
//
// =============================================================================

module chip (
    input  logic        clock,
    input  logic        reset,          // synchronous active-high

    // -------------------------------------------------------------------------
    // AXI-lite slave
    // Simplified: AW+W must arrive in the same cycle; R has no backpressure.
    // -------------------------------------------------------------------------
    input  logic [31:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [31:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,
    output logic [1:0]  s_axil_rresp,

    // -------------------------------------------------------------------------
    // AXI-stream slave  (weight blob first, then per-inference image)
    // -------------------------------------------------------------------------
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast
);

    // =========================================================================
    // Weight-file byte boundaries  (mirrors export.py / weights.bin layout)
    // =========================================================================
    localparam int C1W_LO = 4,      C1W_HI = 75;     // conv1_w   72 B
    // conv1_b: bytes 76-87  — consumed, dropped (no bias port on conv1_stage)
    localparam int C2W_LO = 92,     C2W_HI = 1243;   // conv2_w 1152 B
    // conv2_b: bytes 1244-1263 — consumed, dropped
    localparam int F1W_LO = 1268,   F1W_HI = 26355;  // fc1_w  25088 B
    localparam int F1B_LO = 26360,  F1B_HI = 26391;  // fc1_b     32 B  (int8->int32)
    localparam int F2W_LO = 26396,  F2W_HI = 26715;  // fc2_w    320 B
    localparam int F2B_LO = 26720,  F2B_HI = 26729;  // fc2_b     10 B  (int8->int32)
    localparam int W_TOTAL = 26730;

    // =========================================================================
    // Weight registers — flat; unpacked combinationally to ctrl_seq port shapes
    // =========================================================================
    logic signed [7:0]  c1w [0:71];
    logic signed [7:0]  c2w [0:1151];
    logic signed [7:0]  f1w [0:25087];
    logic signed [31:0] f1b [0:31];
    logic signed [7:0]  f2w [0:319];
    logic signed [31:0] f2b [0:9];

    // Staged (registered) weight arrays fed to ctrl_seq.
    // They only update on the clock edge AFTER wts_done first goes high.
    // This keeps all compute-stage always_comb blocks silent while weights
    // are being written byte-by-byte — solving the O(n²) sim slowdown.
    // conv1 + conv2 + fc2 weights are ECC-protected (SECDED blocks below).
    // fc1 (f1w) stays a plain staged register — see note in the fc1 region.
    logic signed [7:0]  fc1_w_p   [0:31][0:783];
    logic               wts_done_r;

    // ---- conv1 SECDED-protected weight store -------------------------------
    logic [12:0]        c1w_cw  [0:71];   // stored 13-bit SECDED codewords (the protected state)
    logic [12:0]        c1w_enc [0:71];   // encoder outputs (comb, from raw c1w)
    logic signed [7:0]  c1w_dec [0:71];   // decoder corrected data (comb)
    logic [1:0]         c1w_err [0:71];   // per-weight ECC status (00 ok / 01 corrected / 10 double)
    logic signed [7:0]  conv1_w_dec [0:7][0:2][0:2];   // decoded -> conv1 port shape

    // ---- conv2 SECDED-protected weight store (1152 weights) ----------------
    logic [12:0]        c2w_cw  [0:1151];
    logic [12:0]        c2w_enc [0:1151];
    logic signed [7:0]  c2w_dec [0:1151];
    logic [1:0]         c2w_err [0:1151];
    logic signed [7:0]  conv2_w_dec [0:15][0:7][0:2][0:2];  // decoded -> conv2 port shape

    // ---- fc2 SECDED-protected weight store (320 weights) -------------------
    logic [12:0]        f2w_cw  [0:319];
    logic [12:0]        f2w_enc [0:319];
    logic signed [7:0]  f2w_dec [0:319];
    logic [1:0]         f2w_err [0:319];
    logic signed [7:0]  fc2_w_dec [0:9][0:31];              // decoded -> fc2 port shape

    // =========================================================================
    // AXI-stream receiver — weight load phase then image capture phase
    // =========================================================================
    logic [17:0] scnt;          // byte counter (reset between phases)
    logic        wts_done;      // latched after all weight bytes received
    logic [7:0]  img  [0:783];  // image pixel buffer
    logic        img_rdy;       // image loaded, waiting for start_infer

    logic seq_start;            // one-cycle pulse declared here, driven by write path

    assign s_axis_tready = 1'b1;   // always accepting

    always_ff @(posedge clock) begin
        if (reset) begin
            scnt     <= '0;
            wts_done <= 1'b0;
            img_rdy  <= 1'b0;
        end else begin
            if (seq_start) img_rdy <= 1'b0;   // clear on inference start

            if (s_axis_tvalid) begin
                if (!wts_done) begin
                    // ----------------------------------------------------------
                    // Weight load: route byte to correct flat register.
                    // Header bytes and skipped biases fall through unassigned.
                    // ----------------------------------------------------------
                    if (scnt >= C1W_LO && scnt <= C1W_HI)
                        c1w[scnt - C1W_LO] <= signed'(s_axis_tdata);
                    if (scnt >= C2W_LO && scnt <= C2W_HI)
                        c2w[scnt - C2W_LO] <= signed'(s_axis_tdata);
                    if (scnt >= F1W_LO && scnt <= F1W_HI)
                        f1w[scnt - F1W_LO] <= signed'(s_axis_tdata);
                    if (scnt >= F1B_LO && scnt <= F1B_HI)
                        f1b[scnt - F1B_LO] <= {{24{s_axis_tdata[7]}}, s_axis_tdata};
                    if (scnt >= F2W_LO && scnt <= F2W_HI)
                        f2w[scnt - F2W_LO] <= signed'(s_axis_tdata);
                    if (scnt >= F2B_LO && scnt <= F2B_HI)
                        f2b[scnt - F2B_LO] <= {{24{s_axis_tdata[7]}}, s_axis_tdata};

                    if (scnt == W_TOTAL - 1) begin
                        wts_done <= 1'b1;
                        scnt     <= '0;
                    end else begin
                        scnt <= scnt + 18'd1;
                    end

                end else begin
                    // ----------------------------------------------------------
                    // Image capture: 784 bytes, tlast (or count==783) marks end
                    // ----------------------------------------------------------
                    if (scnt < 784) img[scnt[9:0]] <= s_axis_tdata;

                    if (s_axis_tlast || scnt == 18'd783) begin
                        img_rdy <= 1'b1;
                        scnt    <= '0;
                    end else begin
                        scnt <= scnt + 18'd1;
                    end
                end
            end
        end
    end

    // =========================================================================
    // Staged weight latch — fires once on the rising edge of wts_done.
    // Declared here so wts_done is already in scope.
    // =========================================================================
    always_ff @(posedge clock) begin
        wts_done_r <= wts_done;
        if (wts_done && !wts_done_r) begin
            // SECDED-encode conv1 + conv2 weights into their protected codeword
            // stores. Both layers read them back through decoders every cycle.
            for (int i=0;i<72;i++)
                c1w_cw[i] <= c1w_enc[i];
            for (int i=0;i<1152;i++)
                c2w_cw[i] <= c2w_enc[i];
            for (int i=0;i<320;i++)
                f2w_cw[i] <= f2w_enc[i];
            for (int o=0;o<32;o++) for (int i=0;i<784;i++)
                fc1_w_p[o][i] <= f1w[o*784 + i];
        end
    end

    // =========================================================================
    // conv1 weight ECC — SECDED encode-on-store / decode-on-read.
    // 72 codecs: each encodes c1w[i] (latched into c1w_cw at load completion)
    // and decodes the stored codeword c1w_cw[i] live, correcting single-bit
    // upsets. In the fault-free case c1w_dec == c1w, so conv1 sees identical
    // weights and inference is bit-for-bit unchanged.
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 72; gi++) begin : g_c1w_ecc
            ecc_secded u_c1w_ecc (
                .data_in        (c1w[gi]),       // encode side (raw weight)
                .codeword_out   (c1w_enc[gi]),
                .codeword_in    (c1w_cw[gi]),    // decode side (stored codeword)
                .data_corrected (c1w_dec[gi]),
                .error_status   (c1w_err[gi])
            );
        end
    endgenerate

    // Decoded weights reshaped into conv1's [out_ch][kr][kc] port
    always_comb begin
        for (int o=0;o<8;o++) for (int r=0;r<3;r++) for (int c=0;c<3;c++)
            conv1_w_dec[o][r][c] = c1w_dec[o*9 + r*3 + c];
    end

    // Aggregate ECC status across the 72 conv1 weights (drives telemetry).
    logic c1w_any_correct, c1w_any_double;
    always_comb begin
        c1w_any_correct = 1'b0;
        c1w_any_double  = 1'b0;
        for (int i=0;i<72;i++) begin
            if (c1w_err[i] == 2'b01) c1w_any_correct = 1'b1;
            if (c1w_err[i] == 2'b10) c1w_any_double  = 1'b1;
        end
    end

    // =========================================================================
    // conv2 weight ECC — same SECDED pattern, 1152 codecs.
    // =========================================================================
    genvar gj;
    generate
        for (gj = 0; gj < 1152; gj++) begin : g_c2w_ecc
            ecc_secded u_c2w_ecc (
                .data_in        (c2w[gj]),
                .codeword_out   (c2w_enc[gj]),
                .codeword_in    (c2w_cw[gj]),
                .data_corrected (c2w_dec[gj]),
                .error_status   (c2w_err[gj])
            );
        end
    endgenerate

    // Decoded weights reshaped into conv2's [out_ch][in_ch][kr][kc] port
    always_comb begin
        for (int o=0;o<16;o++) for (int i=0;i<8;i++) for (int r=0;r<3;r++) for (int c=0;c<3;c++)
            conv2_w_dec[o][i][r][c] = c2w_dec[o*72 + i*9 + r*3 + c];
    end

    logic c2w_any_correct, c2w_any_double;
    always_comb begin
        c2w_any_correct = 1'b0;
        c2w_any_double  = 1'b0;
        for (int i=0;i<1152;i++) begin
            if (c2w_err[i] == 2'b01) c2w_any_correct = 1'b1;
            if (c2w_err[i] == 2'b10) c2w_any_double  = 1'b1;
        end
    end

    // =========================================================================
    // fc2 weight ECC — same SECDED pattern, 320 codecs.
    // =========================================================================
    genvar gk;
    generate
        for (gk = 0; gk < 320; gk++) begin : g_f2w_ecc
            ecc_secded u_f2w_ecc (
                .data_in        (f2w[gk]),
                .codeword_out   (f2w_enc[gk]),
                .codeword_in    (f2w_cw[gk]),
                .data_corrected (f2w_dec[gk]),
                .error_status   (f2w_err[gk])
            );
        end
    endgenerate

    // Decoded weights reshaped into fc2's [out=10][in=32] port
    always_comb begin
        for (int o=0;o<10;o++) for (int i=0;i<32;i++)
            fc2_w_dec[o][i] = f2w_dec[o*32 + i];
    end

    logic f2w_any_correct, f2w_any_double;
    always_comb begin
        f2w_any_correct = 1'b0;
        f2w_any_double  = 1'b0;
        for (int i=0;i<320;i++) begin
            if (f2w_err[i] == 2'b01) f2w_any_correct = 1'b1;
            if (f2w_err[i] == 2'b10) f2w_any_double  = 1'b1;
        end
    end

    // =========================================================================
    // AXI-lite write path  (AW + W must arrive together)
    // =========================================================================
    logic [2:0] ctrl_r;     // [2]=harden_en [1]=scrub_en; [0] not stored (pulse)

    assign s_axil_awready = 1'b1;
    assign s_axil_wready  = 1'b1;

    always_ff @(posedge clock) begin
        seq_start     <= 1'b0;
        s_axil_bvalid <= 1'b0;
        if (reset) begin
            ctrl_r <= 3'b0;
        end else if (s_axil_awvalid && s_axil_wvalid) begin
            s_axil_bvalid <= 1'b1;
            s_axil_bresp  <= 2'b00;
            if (s_axil_awaddr[7:0] == 8'h00) begin
                ctrl_r[2:1] <= s_axil_wdata[2:1];
                seq_start   <= s_axil_wdata[0];
            end
        end
    end

    // =========================================================================
    // Status tracking
    // =========================================================================
    logic        busy_r, done_r;
    logic [3:0]  class_r;
    logic        seq_done;
    logic [3:0]  seq_class;

    always_ff @(posedge clock) begin
        if (reset) begin
            busy_r  <= 1'b0;
            done_r  <= 1'b0;
            class_r <= 4'h0;
        end else begin
            if (seq_start) begin busy_r <= 1'b1; done_r <= 1'b0; end
            if (seq_done)  begin busy_r <= 1'b0; done_r <= 1'b1; class_r <= seq_class; end
        end
    end

    // =========================================================================
    // AXI-lite read path  (1-cycle pipeline)
    // Telemetry_regs also has 1-cycle registered output, so we fire tel_rd_en
    // combinationally from arvalid — the result lands on the same cycle we
    // present rvalid (one cycle later).
    // =========================================================================
    logic        ar_pend;
    logic [7:0]  ar_addr_lat;
    logic [31:0] tel_rdata;

    logic tel_rd_en_c;
    assign tel_rd_en_c = s_axil_arvalid && !ar_pend &&
                         (s_axil_araddr[7:0] == 8'h10 || s_axil_araddr[7:0] == 8'h14 || s_axil_araddr[7:0] == 8'h18 || s_axil_araddr[7:0] == 8'h1C || s_axil_araddr[7:0] == 8'h30);

    assign s_axil_arready = 1'b1;

    always_ff @(posedge clock) begin
        s_axil_rvalid <= 1'b0;
        if (reset) begin
            ar_pend <= 1'b0;
        end else begin
            if (s_axil_arvalid && !ar_pend) begin
                ar_pend     <= 1'b1;
                ar_addr_lat <= s_axil_araddr[7:0];
            end
            if (ar_pend) begin
                ar_pend       <= 1'b0;
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;
                case (ar_addr_lat)
                    8'h00:   s_axil_rdata <= {29'b0, ctrl_r};
                    8'h04:   s_axil_rdata <= {30'b0, done_r, busy_r};
                    8'h20:   s_axil_rdata <= {28'b0, class_r};
                    default: s_axil_rdata <= tel_rdata;
                endcase
            end
        end
    end

    // =========================================================================
    // ctrl_seq — 7-cycle MNIST inference pipeline
    // =========================================================================
    logic signed [31:0] seq_logits [0:9];

    ctrl_seq u_ctrl_seq (
        .clock           (clock),
        .reset           (reset),
        .start           (seq_start),
        .busy            (),
        .done            (seq_done),
        .image_in        (img),
        .conv1_w         (conv1_w_dec),
        .conv2_w         (conv2_w_dec),
        .fc1_w           (fc1_w_p),
        .fc1_b           (f1b),
        .fc2_w           (fc2_w_dec),
        .fc2_b           (f2b),
        .logits          (seq_logits),
        .predicted_class (seq_class)
    );

    // =========================================================================
    // telemetry_regs — counters + event FIFO
    // ECC / scrubber / TMR strobes are tied to 0 until those modules integrate.
    // =========================================================================
    telemetry_regs #(.FIFO_DEPTH(16)) u_tel (
        .clock                (clock),
        .reset                (reset),
        // Real ECC status from the live conv1 weight path. seq_start gates the
        // pulse to once per inference (counts an inference that read a corrected
        // / uncorrectable conv1 weight). Fault-free => both low => counters hold.
        .scrub_corrections_inc(seq_start & (c1w_any_correct | c2w_any_correct | f2w_any_correct)),
        .ecc_double_errors_inc(seq_start & (c1w_any_double  | c2w_any_double  | f2w_any_double)),
        .tmr_disagreements_inc(1'b0),
        .inferences_total_inc (seq_done),
        .event_push           (1'b0),
        .event_type           (2'b0),
        .event_addr           (16'b0),
        .event_timestamp      (14'b0),
        .reg_addr             (s_axil_araddr[7:0]),
        .reg_rd_en            (tel_rd_en_c),
        .reg_rd_data          (tel_rdata)
    );

endmodule : chip
