// =============================================================================
// tb_chip_ecc_fault.sv — proves chip.sv's conv1 ECC wiring is LIVE (not dead).
//
// Loads real weights + an MNIST image, then runs inference three ways, injecting
// single-event upsets into the STORED conv1 codewords (u_chip.c1w_cw) between
// runs — the same hierarchical-poke technique as the standalone tb_ecc_demo:
//
//   1. clean         -> class 3, scrub 0, ecc2 0
//   2. 1-bit fault   -> class 3 (ECC corrected), scrub 1, ecc2 0
//   3. 2-bit fault   -> ecc2 increments (uncorrectable), class may change
//
// Counters are cumulative/free-running, so the table reports absolute values.
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

    // ---- AXI-lite tasks ----------------------------------------------------
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

    // ---- Backdoor loads (mirror tb_chip_infer) -----------------------------
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
        u_chip.wts_done = 1'b1;     // triggers staging -> c1w_cw SECDED-encoded
        @(posedge clock); #1;
    endtask

    task automatic backdoor_image(input string fn);
        integer fd, i; logic [7:0] b;
        fd = $fopen(fn, "rb");
        for (i=0;i<784;i++) begin void'($fread(b,fd)); u_chip.img[i]=b; end
        $fclose(fd);
        @(posedge clock); #1;
    endtask

    // ---- One inference, returns predicted class ----------------------------
    task automatic run_infer(output logic [3:0] cls);
        logic [31:0] status, rd; integer guard;
        axi_write(32'h0, 32'h1);              // CTRL[0]=1 (start)
        guard=0; status=0;
        while (!(status & 32'h2) && guard < 4000) begin
            axi_read(32'h4, status); guard++;
        end
        axi_read(32'h20, rd); cls = rd[3:0];  // LAST_OUTPUT
    endtask

    task automatic read_tel(output logic [31:0] scrub, output logic [31:0] ecc2);
        axi_read(32'h10, scrub);
        axi_read(32'h14, ecc2);
    endtask

    string img_path;
    logic [3:0]  c0, c1, c2;
    logic [31:0] s0, e0, s1, e1, s2, e2;
    localparam int IDX = 0;     // conv1 weight whose codeword gets the SEU

    initial begin
        if (!$value$plusargs("IMG=%s", img_path)) img_path = "/tmp/img0.bin";

        repeat(6) @(posedge clock); #1; reset = 0; @(posedge clock); #1;
        backdoor_weights("weights.bin");
        backdoor_image(img_path);

        // ---- 1. CLEAN ----------------------------------------------------
        run_infer(c0); read_tel(s0, e0);

        // ---- 2. SINGLE-BIT FAULT: flip one bit of stored codeword IDX ----
        u_chip.c1w_cw[IDX][5] = ~u_chip.c1w_cw[IDX][5];
        run_infer(c1); read_tel(s1, e1);

        // ---- 3. DOUBLE-BIT FAULT: flip a SECOND bit of the same codeword -
        u_chip.c1w_cw[IDX][2] = ~u_chip.c1w_cw[IDX][2];
        run_infer(c2); read_tel(s2, e2);

        $display("============================================================");
        $display(" chip-level ECC liveness proof (conv1 weight codeword [%0d])", IDX);
        $display(" run             class   scrub_corrections   ecc_double_errors");
        $display(" clean             %0d            %0d                  %0d", c0, s0, e0);
        $display(" 1-bit fault       %0d            %0d                  %0d", c1, s1, e1);
        $display(" 2-bit fault       %0d            %0d                  %0d", c2, s2, e2);
        $display("============================================================");

        if (c0==3 && s0==0 && e0==0 &&
            c1==3 && s1==1 && e1==0 &&
            e2==1) begin
            $display(" ECC LIVE PASS: 1-bit fault corrected (class held 3, scrub 1);");
            $display("                2-bit fault flagged uncorrectable (ecc2 1).");
        end else begin
            $display(" ECC LIVE FAIL: c0=%0d s0=%0d e0=%0d | c1=%0d s1=%0d e1=%0d | c2=%0d s2=%0d e2=%0d",
                     c0,s0,e0,c1,s1,e1,c2,s2,e2);
        end
        $display("============================================================");
        $finish;
    end
endmodule : tb_chip_ecc_fault
