// =============================================================================
// tb_accel_server.sv
// Long-running TCP/DPI-C sim server for accel_top — the real-chip counterpart
// to host/stub_sim_server.py. Speaks the same READ/WRITE/STREAM/INJECT text
// protocol as host/sim_backend.py expects, on TCP port 9000, but drives the
// actual accel_top RTL instead of faking responses in Python.
//
// Usage (two terminals, exactly like the stub):
//   Terminal 1:  build + run this testbench's sim binary (it blocks, serving
//                forever — Ctrl-C to stop)
//   Terminal 2:  python3 host/sim_backend.py   (or host/runner.py, driver.py)
//
// This targets accel_top specifically because it's the only fully-wired
// integration top that exists today; accel_top has no AXI-lite/telemetry
// register file of its own, so the register map below is a *testbench-side*
// decode, not synthesizable RTL. Once a real register-mapped chip top lands
// (matching host/driver.py's CTRL/STATUS/telemetry addresses), the DPI-C
// server in sim_tcp_dpi.c can be reused unchanged behind a new tb_chip_server
// wired to that top — only the command-decode block below would need to move.
//
// =============================================================================
// REGISTER MAP (testbench-side decode over accel_top's ports)
// =============================================================================
//   WRITE 0x00..0x3F   -> weight_mem[addr] = val[7:0]      (preload one weight)
//   WRITE 0x40         -> pulse start for one clock         (val ignored)
//   WRITE 0x41..0x48   -> activations[addr-0x41] = val[7:0]
//   READ  0x50         -> {31'b0, done_latch}                (set on done,
//                                                              cleared by start)
//   READ  0x60..0x67   -> results[addr-0x60], sign-extended to 32 bits
//   READ  (other)      -> 0x00000000
//   STREAM 64 bytes    -> bulk-load weight_mem[0..63]
//   STREAM 8  bytes    -> bulk-load activations[0..7]
//   STREAM (other n)   -> bytes are drained but otherwise ignored
//   INJECT 0 addr bit  -> flip bit `bit` of weight_mem.mem[addr]
//   INJECT 1 *   *     -> no act_mem on accel_top — logged as a no-op
// =============================================================================

module tb_accel_server;

    // -------------------------------------------------------------------------
    // DPI-C imports — see sim_tcp_dpi.c
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

    // -------------------------------------------------------------------------
    // DUT signal declarations
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;

    logic                   wr_en;
    logic        [5:0]      wr_addr;
    logic signed [7:0]      wr_data;

    logic                   start;
    logic                   done;

    logic signed [7:0]      activations [0:7];
    logic signed [18:0]     results     [0:7];

    logic                   done_latch;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    accel_top dut (
        .clock       (clock),
        .reset       (reset),
        .wr_en       (wr_en),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .start       (start),
        .done        (done),
        .activations (activations),
        .results     (results)
    );

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // done_latch — sticky STATUS-style bit: set when accel_top.done pulses,
    // cleared when a new inference is kicked off (start pulse)
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset || start) begin
            done_latch <= 1'b0;
        end else if (done) begin
            done_latch <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Helper: sign-extend a 19-bit MAC result to 32 bits
    // -------------------------------------------------------------------------
    function automatic logic [31:0] sext_result(input int idx);
        return {{13{results[idx][18]}}, results[idx]};
    endfunction

    // -------------------------------------------------------------------------
    // Helper: drive one weight_mem write for one clock edge
    // -------------------------------------------------------------------------
    task automatic write_weight(input logic [5:0] addr, input logic [7:0] data);
        wr_en   = 1'b1;
        wr_addr = addr;
        wr_data = signed'(data);
        @(posedge clock); #1;
        wr_en   = 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main server loop
    // -------------------------------------------------------------------------
    int cmd, arg0, arg1, arg2;
    int got_cmd;
    int k;

    initial begin
        $dumpfile("accel_server.fst");
        $dumpvars(0);

        // ---------------------------------------------------------------------
        // Reset
        // ---------------------------------------------------------------------
        reset   = 1'b1;
        wr_en   = 1'b0;
        wr_addr = 6'h00;
        wr_data = 8'sd0;
        start   = 1'b0;
        for (k = 0; k < 8; k++) activations[k] = 8'sd0;

        @(posedge clock); #1;
        @(posedge clock); #1;
        reset = 1'b0;

        if (dpi_listen(SIM_PORT) != 0) begin
            $fatal(1, "tb_accel_server: dpi_listen failed");
        end

        // ---------------------------------------------------------------------
        // Accept clients forever, one at a time (mirrors stub_sim_server.py)
        // ---------------------------------------------------------------------
        forever begin
            if (dpi_accept() != 0) begin
                $fatal(1, "tb_accel_server: dpi_accept failed");
            end

            // -------------------------------------------------------------------
            // Serve commands until the client disconnects
            // -------------------------------------------------------------------
            got_cmd = 1;
            while (got_cmd) begin
                got_cmd = dpi_next_cmd(cmd, arg0, arg1, arg2);
                if (!got_cmd) begin
                    dpi_close_client();
                end else begin
                    case (cmd)

                        // -----------------------------------------------------------
                        // Every register access — including reads — costs one
                        // clock edge. This matters: the simulated clock only
                        // advances while SV code is actively stepping it, since
                        // a blocking DPI call (waiting on the next TCP command)
                        // freezes the whole process, including the free-running
                        // `always #5 clock = ~clock` generator. Without this,
                        // a host-side poll loop (read STATUS in a spin loop)
                        // would observe the same unchanging cycle forever.
                        CMD_READ: begin
                            @(posedge clock); #1;
                            if (arg0 == 'h50) begin
                                dpi_send_data({31'b0, done_latch});
                            end else if (arg0 >= 'h60 && arg0 <= 'h67) begin
                                dpi_send_data(sext_result(arg0 - 'h60));
                            end else begin
                                dpi_send_data(32'h0);
                            end
                        end

                        // -----------------------------------------------------------
                        CMD_WRITE: begin
                            if (arg0 <= 'h3F) begin
                                write_weight(arg0[5:0], arg1[7:0]);
                            end else if (arg0 == 'h40) begin
                                start = 1'b1;
                                @(posedge clock); #1;
                                start = 1'b0;
                            end else if (arg0 >= 'h41 && arg0 <= 'h48) begin
                                activations[arg0 - 'h41] = signed'(arg1[7:0]);
                                @(posedge clock); #1;
                            end
                            dpi_send_ok();
                        end

                        // -----------------------------------------------------------
                        CMD_STREAM: begin
                            if (arg0 == 64) begin
                                wr_en = 1'b1;
                                for (k = 0; k < 64; k++) begin
                                    wr_addr = k[5:0];
                                    wr_data = signed'(dpi_stream_byte(k)[7:0]);
                                    @(posedge clock); #1;
                                end
                                wr_en = 1'b0;
                            end else if (arg0 == 8) begin
                                for (k = 0; k < 8; k++)
                                    activations[k] = signed'(dpi_stream_byte(k)[7:0]);
                                @(posedge clock); #1;
                            end
                            dpi_send_ok();
                        end

                        // -----------------------------------------------------------
                        CMD_INJECT: begin
                            if (arg0 == 0) begin
                                dut.u_weight_mem.mem[arg1] =
                                    dut.u_weight_mem.mem[arg1] ^ (8'b1 << arg2[2:0]);
                                $display("SIM_SERVER: t=%0t INJECT mem_id=0 addr=%0d bit=%0d",
                                          $time, arg1, arg2);
                            end else begin
                                $display("SIM_SERVER: t=%0t INJECT mem_id=%0d not supported on accel_top — no-op",
                                          $time, arg0);
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

endmodule : tb_accel_server
