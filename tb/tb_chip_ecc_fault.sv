// =============================================================================
// tb_chip_ecc_fault.sv — proves chip.sv's weight-ECC wiring is LIVE for every
// ECC-protected array (conv1 c1w, conv2 c2w, fc2 f2w).
//
// Loads real weights + an MNIST image, then for each protected array injects
// SEUs into the STORED codewords (u_chip.*_cw) and re-runs inference:
//   single-bit  -> corrected   -> class held at 3, scrub_corrections +1
//   double-bit  -> uncorrectable-> ecc_double_errors +1, class may change
// Faults are undone (flipped back) between arrays so each starts clean.
// Telemetry counters are cumulative/free-running, so the table reports deltas.
//
// NOTE: fc1 (f1w, 25,088 weights) is NOT ECC-protected — the per-entry codec
// pattern needs 25,088 codecs (measured: ~407 MB sim binary), infeasible. It
// needs a sequential decode keyed to fc1's pipelined access; see report.
// =============================================================================
`timescale 1ns/1ps
module tb_chip_ecc_fault;

    logic clock=0, reset=1;

    logic [31:0] s_axil_awaddr=0; logic s_axil_awvalid=0; logic s_axil_awready;
    logic [31:0] s_axil_wdata=0;  logic s_axil_wvalid=0;  logic s_axil_wready;
    logic [1:0]  s_axil_bresp;    logic s_axil_bvalid;    logic s_axil_bready=0;
    logic [31:0] s_axil_araddr=0; logic s_axil_arvalid=0; logic s_axil_arready;
    logic [31:0] s_axil_rdata;    logic s_axil_rvalid;    logic s_axil_rready=0;
    logic [1:0]  s_axil_rresp;

    logic [7:0] s_axis_tdata=0; logic s_axis_tvalid=0;
    logic s_axis_tready;        logic s_axis_tlast=0;

    always #5 clock = ~clock;

    chip u_chip (
        .clock(clock),.reset(reset),
        .s_axil_awaddr(s_axil_awaddr),.s_axil_awvalid(s_axil_awvalid),.s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),  .s_axil_wvalid(s_axil_wvalid),  .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),  .s_axil_bvalid(s_axil_bvalid),  .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),.s_axil_arvalid(s_axil_arvalid),.s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),  .s_axil_rvalid(s_axil_rvalid),  .s_axil_rready(s_axil_rready),
        .s_axil_rresp(s_axil_rresp),
        .s_axis_tdata(s_axis_tdata),  .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),.s_axis_tlast(s_axis_tlast)
    );

    task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
        @(posedge clock); #1;
        s_axil_awaddr=addr; s_axil_awvalid=1;
        s_axil_wdata=data;  s_axil_wvalid=1; s_axil_bready=1;
        @(posedge clock); #1; s_axil_awvalid=0; s_axil_wvalid=0;
        @(posedge clock); #1; s_axil_bready=0;
    endtask

    task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
        @(posedge clock); #1;
        s_axil_araddr=addr; s_axil_arvalid=1; s_axil_rready=1;
        @(posedge clock); #1; s_axil_arvalid=0;
        @(posedge clock); #1;
        data=s_axil_rdata; s_axil_rready=0;
    endtask

    task automatic backdoor_weights(input string fn);
        integer fd, i; logic [7:0] b;
        fd = $fopen(fn, "rb");
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<72;i++)    begin void'($fread(b,fd)); u_chip.c1w[i]=signed'(b); end
        for (i=0;i<4+8;i++) void'($fread(b,fd));
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<1152;i++)  begin void'($fread(b,fd)); u_chip.c2w[i]=signed'(b); end
        for (i=0;i<4+16;i++) void'($fread(b,fd));
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<25088;i++) begin void'($fread(b,fd)); u_chip.f1w[i]=signed'(b); end
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<32;i++)    begin void'($fread(b,fd)); u_chip.f1b[i]={{24{b[7]}},b}; end
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<320;i++)   begin void'($fread(b,fd)); u_chip.f2w[i]=signed'(b); end
        for (i=0;i<4;i++) void'($fread(b,fd));
        for (i=0;i<10;i++)    begin void'($fread(b,fd)); u_chip.f2b[i]={{24{b[7]}},b}; end
        $fclose(fd);
        u_chip.wts_done = 1'b1;
        @(posedge clock); #1;
    endtask

    task automatic backdoor_image(input string fn);
        integer fd, i; logic [7:0] b;
        fd = $fopen(fn, "rb");
        for (i=0;i<784;i++) begin void'($fread(b,fd)); u_chip.img[i]=b; end
        $fclose(fd);
        @(posedge clock); #1;
    endtask

    task automatic run_infer(output logic [3:0] cls);
        logic [31:0] status, rd; integer guard;
        axi_write(32'h0, 32'h1);
        guard=0; status=0;
        while (!(status & 32'h2) && guard < 4000) begin
            axi_read(32'h4, status); guard++;
        end
        axi_read(32'h20, rd); cls = rd[3:0];
    endtask

    task automatic read_tel(output logic [31:0] scrub, output logic [31:0] ecc2);
        axi_read(32'h10, scrub);
        axi_read(32'h14, ecc2);
    endtask

    // Inject single (bit5) / double (bit5+bit2) into a stored codeword and undo.
    // Hierarchical paths can't be parameterised, so one macro pair per array.
    `define SINGLE(P) u_chip.P[0][5] = ~u_chip.P[0][5]
    `define SECOND(P) u_chip.P[0][2] = ~u_chip.P[0][2]

    string img_path;
    logic [3:0]  c;
    logic [31:0] s, e, ps, pe;
    integer fail;

    initial begin
        if (!$value$plusargs("IMG=%s", img_path)) img_path = "tb/demo_img0.bin";
        fail = 0;

        repeat(6) @(posedge clock); #1; reset = 0; @(posedge clock); #1;
        backdoor_weights("weights.bin");
        backdoor_image(img_path);

        $display("============================================================");
        $display(" RAD-HARD-AI  —  chip-level weight-ECC liveness");
        $display(" image=%s   protected arrays: c1w(conv1) c2w(conv2) f2w(fc2)", img_path);
        $display("------------------------------------------------------------");
        $display(" scenario       class   scrub(delta)   ecc2(delta)   verdict");
        $display("------------------------------------------------------------");

        // ---- clean baseline ---------------------------------------------
        run_infer(c); read_tel(s, e); ps=s; pe=e;
        $display(" clean            %0d       %0d (+0)        %0d (+0)     baseline", c, s, e);
        $display("RESULT clean class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!(c==3 && s==0 && e==0)) fail++;

        // ================= conv1 (c1w) ===================================
        `SINGLE(c1w_cw);                 run_infer(c); read_tel(s,e);
        $display(" c1w 1-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, (c==3 && (s-ps)==1) ? "CORRECTED" : "FAIL");
        $display("RESULT c1w_single class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!(c==3 && (s-ps)==1 && (e-pe)==0)) fail++;
        `SINGLE(c1w_cw); ps=s; pe=e;     // undo
        `SINGLE(c1w_cw); `SECOND(c1w_cw); run_infer(c); read_tel(s,e);
        $display(" c1w 2-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, ((e-pe)==1) ? "DETECTED" : "FAIL");
        $display("RESULT c1w_double class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!((e-pe)==1)) fail++;
        `SINGLE(c1w_cw); `SECOND(c1w_cw); ps=s; pe=e;   // undo

        // ================= conv2 (c2w) ===================================
        `SINGLE(c2w_cw);                 run_infer(c); read_tel(s,e);
        $display(" c2w 1-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, (c==3 && (s-ps)==1) ? "CORRECTED" : "FAIL");
        $display("RESULT c2w_single class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!(c==3 && (s-ps)==1 && (e-pe)==0)) fail++;
        `SINGLE(c2w_cw); ps=s; pe=e;
        `SINGLE(c2w_cw); `SECOND(c2w_cw); run_infer(c); read_tel(s,e);
        $display(" c2w 2-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, ((e-pe)==1) ? "DETECTED" : "FAIL");
        $display("RESULT c2w_double class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!((e-pe)==1)) fail++;
        `SINGLE(c2w_cw); `SECOND(c2w_cw); ps=s; pe=e;

        // ================= fc2 (f2w) =====================================
        `SINGLE(f2w_cw);                 run_infer(c); read_tel(s,e);
        $display(" f2w 1-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, (c==3 && (s-ps)==1) ? "CORRECTED" : "FAIL");
        $display("RESULT f2w_single class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!(c==3 && (s-ps)==1 && (e-pe)==0)) fail++;
        `SINGLE(f2w_cw); ps=s; pe=e;
        `SINGLE(f2w_cw); `SECOND(f2w_cw); run_infer(c); read_tel(s,e);
        $display(" f2w 2-bit        %0d       %0d (+%0d)        %0d (+%0d)     %s",
                 c, s, s-ps, e, e-pe, ((e-pe)==1) ? "DETECTED" : "FAIL");
        $display("RESULT f2w_double class=%0d scrub=%0d ecc2=%0d", c, s, e);
        if (!((e-pe)==1)) fail++;
        `SINGLE(f2w_cw); `SECOND(f2w_cw);

        $display("------------------------------------------------------------");
        if (fail==0)
            $display(" ECC LIVE PASS: single-bit corrected (class held, scrub+1),");
        else
            $display(" ECC LIVE FAIL: %0d check(s) failed", fail);
        $display("              double-bit detected (ecc2+1) for c1w, c2w, f2w.");
        $display(" (fc1 f1w not ECC-protected: 25,088-codec parallel pattern");
        $display("  infeasible; needs sequential decode — deferred.)");
        $display("============================================================");
        $display("RESULT verdict pass=%0d fails=%0d", (fail==0), fail);
        $finish;
    end
endmodule : tb_chip_ecc_fault
