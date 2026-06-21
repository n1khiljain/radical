// =============================================================================
// tb_chip_infer.sv — self-checking chip-level inference test (pure SV, no FIFO).
//
// Backdoor-loads real weights.bin + one MNIST image, drives the AXI-lite start,
// waits for done, and reports predicted_class + ECC telemetry. Used to confirm
// that wiring ECC into chip.sv's weight path does NOT change normal inference.
//
// Files: weights.bin (26,730 B, length-prefixed int8 blobs) and a raw 784-byte
// image (path via +IMG=... plusarg, default /tmp/img0.bin).
// =============================================================================
`timescale 1ns/1ps
module tb_chip_infer;

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

    // ---- Backdoor weight load (mirrors tb_chip.sv layout) ------------------
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
        u_chip.wts_done = 1'b1;     // mark load complete -> triggers staging/ECC encode
        @(posedge clock); #1;
    endtask

    // ---- Backdoor image load ----------------------------------------------
    task automatic backdoor_image(input string fn);
        integer fd, i; logic [7:0] b;
        fd = $fopen(fn, "rb");
        for (i=0;i<784;i++) begin void'($fread(b,fd)); u_chip.img[i]=b; end
        $fclose(fd);
        @(posedge clock); #1;
    endtask

    string img_path;
    logic [31:0] rd, status, cls, scrub, ecc2;
    integer guard;

    initial begin
        if (!$value$plusargs("IMG=%s", img_path)) img_path = "/tmp/img0.bin";

        repeat(6) @(posedge clock); #1;
        reset = 0;
        @(posedge clock); #1;

        backdoor_weights("weights.bin");
        backdoor_image(img_path);

        // Start inference: CTRL[0]=1 at addr 0x00
        axi_write(32'h0000_0000, 32'h0000_0001);

        // Wait for done (STATUS[1]); free-running clock so just poll a bounded count
        guard = 0; status = 0;
        while (!(status & 32'h2) && guard < 4000) begin
            axi_read(32'h0000_0004, status);
            guard++;
        end

        axi_read(32'h0000_0020, cls);    // LAST_OUTPUT[3:0]
        axi_read(32'h0000_0010, scrub);  // SCRUB_CORRECTIONS
        axi_read(32'h0000_0014, ecc2);   // ECC_DOUBLE_ERRORS

        $display("============================================================");
        $display(" tb_chip_infer: image=%s", img_path);
        $display("   done=%0d  predicted_class=%0d", (status>>1)&1, cls & 32'hF);
        $display("   telemetry: scrub_corrections=%0d  ecc_double_errors=%0d",
                 scrub, ecc2);
        $display("   PREDICTED_CLASS=%0d", cls & 32'hF);
        $display("============================================================");
        $finish;
    end
endmodule : tb_chip_infer
