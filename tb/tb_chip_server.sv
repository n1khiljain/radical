// =============================================================================
// tb_chip_server.sv
// Long-running TCP/DPI-C sim server for the real chip top — successor to
// tb_accel_server.sv now that chip.sv exists with the actual register map
// host/driver.py expects. Reuses sim_tcp_dpi.c unchanged; only the
// command-decode block below is chip-specific, driving chip.sv's AXI-lite
// slave and AXI-stream slave ports instead of accel_top's raw weight_mem
// write port.
//
// Usage (two terminals, same as tb_accel_server.sv / the stub):
//   Terminal 1:  build + run this testbench's sim binary (blocks, serving
//                forever — Ctrl-C to stop)
//   Terminal 2:  python3 -m host.driver   (or anything using SimBackend)
//
// =============================================================================
// REGISTER MAP — pass-through to chip.sv's real AXI-lite address map
// =============================================================================
//   WRITE addr val  -> single AXI-lite write transaction (addr, val)
//                      chip.sv only acts on addr==0x00 (CTRL); writes to other
//                      addresses are acknowledged (bvalid) and otherwise
//                      ignored, exactly like real unmapped-but-decoded RTL.
//   READ  addr      -> single AXI-lite read transaction; reply is whatever
//                      chip.sv returns for that address (0x00 CTRL, 0x04
//                      STATUS, 0x10/0x14/0x18/0x1C telemetry counters via
//                      telemetry_regs, 0x20 LAST_OUTPUT, 0x30 EVENT_POP
//                      destructive pop, 0 for anything else).
//   STREAM n bytes  -> n bytes pushed through s_axis_tdata/tvalid, one byte
//                      per clock, tlast asserted on the final byte. chip.sv
//                      itself decides whether those bytes are weight-load
//                      payload or image payload via its internal wts_done
//                      latch — the testbench does not need to track phase.
//                      host/driver.py's load_weights() streams the full
//                      26,730-byte weights.bin; run_inference() streams 784
//                      image bytes.
//   INJECT mem_id addr bit_idx -> flip one bit via hierarchical reference into
//                      the chip's internal flat weight/image registers:
//                        mem_id 0 -> c1w  (conv1 weights,   72 entries, 8b)
//                        mem_id 1 -> c2w  (conv2 weights, 1152 entries, 8b)
//                        mem_id 2 -> f1w  (fc1 weights,  25088 entries, 8b)
//                        mem_id 3 -> f2w  (fc2 weights,    320 entries, 8b)
//                        mem_id 4 -> img  (current image,   784 entries, 8b)
//                      Matches mock/behavioral_chip.py's WEIGHT_KEYS fault
//                      surface (conv1_w/conv2_w/fc1_w/fc2_w) plus the image
//                      buffer. fc1_b/fc2_b (biases) are intentionally not
//                      injectable here, same as the software fault model.
//
//                      NOTE: chip.sv ties scrub_corrections_inc /
//                      ecc_double_errors_inc / tmr_disagreements_inc to 1'b0
//                      (the ECC/scrubber/TMR hardening RTL hasn't been wired
//                      in yet). INJECT will visibly corrupt the targeted
//                      weight/pixel — observable via a changed LAST_OUTPUT on
//                      the next inference — but will NOT increment
//                      ECC_DERR/TMR_DISAG until that hardening logic lands.
// =============================================================================

module tb_chip_server;

    // -------------------------------------------------------------------------
    // DPI-C imports — see sim_tcp_dpi.c (unchanged from tb_accel_server.sv)
    // -------------------------------------------------------------------------
    import "DPI-C" function int dpi_listen(input int port);
    import "DPI-C" function int dpi_accept();
    import "DPI-C" function void dpi_close_client();
    import "DPI-C" function int dpi_next_cmd(output int cmd, output int arg0,
                                              output int arg1, output int arg2);
    import "DPI-C" function int dpi_stream_byte(input int idx);
    import "DPI-C" function void dpi_send_ok();
    import "DPI-C" function void dpi_send_data(input int unsigned val);

    localparam int CMD_READ    = 0;
    localparam int CMD_WRITE   = 1;
    localparam int CMD_STREAM  = 2;
    localparam int CMD_INJECT  = 3;

    localparam int SIM_PORT    = 9000;

    // Bound on cycles a single read/transaction will wait before giving up —
    // keeps a wedged transaction from hanging the server forever.
    localparam int MAX_WAIT_CYCLES = 10000;

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic        clock;
    logic        reset;

    logic [31:0] s_axil_awaddr;
    logic        s_axil_awvalid;
    logic        s_axil_awready;
    logic [31:0] s_axil_wdata;
    logic        s_axil_wvalid;
    logic        s_axil_wready;
    logic [1:0]  s_axil_bresp;
    logic        s_axil_bvalid;
    logic        s_axil_bready;
    logic [31:0] s_axil_araddr;
    logic        s_axil_arvalid;
    logic        s_axil_arready;
    logic [31:0] s_axil_rdata;
    logic        s_axil_rvalid;
    logic        s_axil_rready;
    logic [1:0]  s_axil_rresp;

    logic [7:0]  s_axis_tdata;
    logic        s_axis_tvalid;
    logic        s_axis_tready;
    logic        s_axis_tlast;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    chip dut (
        .clock          (clock),
        .reset          (reset),

        .s_axil_awaddr  (s_axil_awaddr),
        .s_axil_awvalid (s_axil_awvalid),
        .s_axil_awready (s_axil_awready),
        .s_axil_wdata   (s_axil_wdata),
        .s_axil_wvalid  (s_axil_wvalid),
        .s_axil_wready  (s_axil_wready),
        .s_axil_bresp   (s_axil_bresp),
        .s_axil_bvalid  (s_axil_bvalid),
        .s_axil_bready  (s_axil_bready),
        .s_axil_araddr  (s_axil_araddr),
        .s_axil_arvalid (s_axil_arvalid),
        .s_axil_arready (s_axil_arready),
        .s_axil_rdata   (s_axil_rdata),
        .s_axil_rvalid  (s_axil_rvalid),
        .s_axil_rready  (s_axil_rready),
        .s_axil_rresp   (s_axil_rresp),

        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast)
    );

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // AXI-lite write — single transaction, no backpressure on this DUT
    // -------------------------------------------------------------------------
    task automatic axil_write(input logic [31:0] addr, input logic [31:0] data);
        s_axil_awaddr  = addr;
        s_axil_wdata   = data;
        s_axil_awvalid = 1'b1;
        s_axil_wvalid  = 1'b1;
        s_axil_bready  = 1'b1;
        @(posedge clock); #1;
        s_axil_awvalid = 1'b0;
        s_axil_wvalid  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // AXI-lite read — single transaction; polls rvalid with a bounded wait
    // -------------------------------------------------------------------------
    task automatic axil_read(input logic [31:0] addr, output logic [31:0] data);
        int waited;
        s_axil_araddr  = addr;
        s_axil_arvalid = 1'b1;
        s_axil_rready  = 1'b1;
        @(posedge clock); #1;
        s_axil_arvalid = 1'b0;

        waited = 0;
        while (!s_axil_rvalid && waited < MAX_WAIT_CYCLES) begin
            @(posedge clock); #1;
            waited++;
        end

        if (!s_axil_rvalid) begin
            $display("SIM_SERVER: WARNING: axil_read(0x%0h) timed out after %0d cycles",
                      addr, MAX_WAIT_CYCLES);
            data = 32'h0;
        end else begin
            data = s_axil_rdata;
        end
    endtask

    // -------------------------------------------------------------------------
    // AXI-stream send — n bytes from the DPI stream buffer, one per clock,
    // tlast asserted on the final byte. chip.sv has no backpressure
    // (s_axis_tready is tied high), so this is a simple fixed-rate push.
    // -------------------------------------------------------------------------
    task automatic axis_send_stream(input int n_bytes);
        int i;
        for (i = 0; i < n_bytes; i++) begin
            s_axis_tdata  = dpi_stream_byte(i)[7:0];
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = (i == n_bytes - 1) ? 1'b1 : 1'b0;
            @(posedge clock); #1;
        end
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main server loop
    // -------------------------------------------------------------------------
    int cmd, arg0, arg1, arg2;
    int got_cmd;
    logic [31:0] rd_val;

    initial begin
        $dumpfile("chip_server.fst");
        $dumpvars(0);

        // ---------------------------------------------------------------------
        // Reset
        // ---------------------------------------------------------------------
        reset          = 1'b1;
        s_axil_awaddr  = '0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata   = '0;
        s_axil_wvalid  = 1'b0;
        s_axil_bready  = 1'b1;
        s_axil_araddr  = '0;
        s_axil_arvalid = 1'b0;
        s_axil_rready  = 1'b1;
        s_axis_tdata   = '0;
        s_axis_tvalid  = 1'b0;
        s_axis_tlast   = 1'b0;

        @(posedge clock); #1;
        @(posedge clock); #1;
        reset = 1'b0;

        if (dpi_listen(SIM_PORT) != 0) begin
            $fatal(1, "tb_chip_server: dpi_listen failed");
        end

        // ---------------------------------------------------------------------
        // Accept clients forever, one at a time (mirrors stub_sim_server.py)
        // ---------------------------------------------------------------------
        forever begin
            if (dpi_accept() != 0) begin
                $fatal(1, "tb_chip_server: dpi_accept failed");
            end

            got_cmd = 1;
            while (got_cmd) begin
                got_cmd = dpi_next_cmd(cmd, arg0, arg1, arg2);
                if (!got_cmd) begin
                    dpi_close_client();
                end else begin
                    case (cmd)

                        // -----------------------------------------------------------
                        CMD_READ: begin
                            axil_read(arg0, rd_val);
                            dpi_send_data(rd_val);
                        end

                        // -----------------------------------------------------------
                        CMD_WRITE: begin
                            axil_write(arg0, arg1);
                            dpi_send_ok();
                        end

                        // -----------------------------------------------------------
                        CMD_STREAM: begin
                            axis_send_stream(arg0);
                            dpi_send_ok();
                        end

                        // -----------------------------------------------------------
                        CMD_INJECT: begin
                            case (arg0)
                                0: dut.c1w[arg1] = dut.c1w[arg1] ^ (8'b1 << arg2[2:0]);
                                1: dut.c2w[arg1] = dut.c2w[arg1] ^ (8'b1 << arg2[2:0]);
                                2: dut.f1w[arg1] = dut.f1w[arg1] ^ (8'b1 << arg2[2:0]);
                                3: dut.f2w[arg1] = dut.f2w[arg1] ^ (8'b1 << arg2[2:0]);
                                4: dut.img[arg1] = dut.img[arg1] ^ (8'b1 << arg2[2:0]);
                                default: $display("SIM_SERVER: t=%0t INJECT mem_id=%0d not supported on chip — no-op",
                                                   $time, arg0);
                            endcase
                            if (arg0 inside {0, 1, 2, 3, 4}) begin
                                $display("SIM_SERVER: t=%0t INJECT mem_id=%0d addr=%0d bit=%0d",
                                          $time, arg0, arg1, arg2);
                            end
                            dpi_send_ok();
                        end

                        // -----------------------------------------------------------
                        default: begin
                            // Malformed-command replies are already sent by
                            // dpi_next_cmd() itself; nothing further to do.
                        end

                    endcase
                end
            end
        end
    end

endmodule : tb_chip_server
