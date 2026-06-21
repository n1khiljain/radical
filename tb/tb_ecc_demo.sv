// =============================================================================
// tb_ecc_demo.sv — self-contained radiation-hardening demo.
//
// Proves the hardening thesis in REAL RTL (no chip.sv, no conv stages, no host)
// using only:  weight_mem_ecc + ecc_secded + mac_array + telemetry_regs.
// Compiles in seconds (iverilog or `verilator --binary`).
//
// One weight row (8 INT8 weights) is SECDED-encoded into weight_mem_ecc and fed
// to one MAC dot-product unit. The SAME single-bit SEU (a bit-flip in a stored
// codeword) is then shown THREE ways:
//
//   A. NO FAULT          -> MAC output = golden, no telemetry
//   B. FAULT, ECC OFF    -> raw (uncorrected) weight is wrong -> MAC output wrong,
//                           no counter moves   (the unhardened baseline)
//   C. FAULT, ECC ON     -> decoder corrects the weight -> MAC output = golden,
//                           scrub_corrections counter increments + event pushed
//
// Self-checking: prints DEMO PASS / DEMO FAIL.
// =============================================================================
`timescale 1ns/1ps
module tb_ecc_demo;

    // ---- DUT-facing signals ------------------------------------------------
    logic                clock = 0;
    logic                reset = 1;

    // weight_mem_ecc
    logic                wr_en = 0;
    logic [14:0]         wr_addr = 0;
    logic signed [7:0]   wr_data = 0;
    logic [14:0]         rd_addr = 0;
    logic signed [7:0]   rd_data;
    logic [1:0]          rd_error_status;

    // mac_array
    logic signed [7:0]   weights [0:7][0:7];
    logic signed [7:0]   activations [0:7];
    logic signed [18:0]  results [0:7];

    // telemetry_regs
    logic                scrub_corrections_inc = 0;
    logic                ecc_double_errors_inc = 0;
    logic                tmr_disagreements_inc = 0;
    logic                inferences_total_inc  = 0;
    logic                event_push = 0;
    logic [1:0]          event_type = 0;
    logic [15:0]         event_addr = 0;
    logic [13:0]         event_timestamp = 0;
    logic [7:0]          reg_addr = 0;
    logic                reg_rd_en = 0;
    logic [31:0]         reg_rd_data;

    // ---- DUTs --------------------------------------------------------------
    weight_mem_ecc u_wmem (
        .clock(clock), .reset(reset),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_addr(rd_addr), .rd_data(rd_data), .rd_error_status(rd_error_status)
    );

    mac_array u_mac (
        .clock(clock), .reset(reset),
        .weights(weights), .activations(activations), .results(results)
    );

    telemetry_regs #(.FIFO_DEPTH(16)) u_tel (
        .clock(clock), .reset(reset),
        .scrub_corrections_inc(scrub_corrections_inc),
        .ecc_double_errors_inc(ecc_double_errors_inc),
        .tmr_disagreements_inc(tmr_disagreements_inc),
        .inferences_total_inc (inferences_total_inc),
        .event_push(event_push), .event_type(event_type),
        .event_addr(event_addr), .event_timestamp(event_timestamp),
        .reg_addr(reg_addr), .reg_rd_en(reg_rd_en), .reg_rd_data(reg_rd_data)
    );

    always #5 clock = ~clock;

    // ---- Stimulus ----------------------------------------------------------
    localparam int N = 8;
    logic signed [7:0] gw [0:N-1];        // golden weights
    logic signed [7:0] act [0:N-1];       // activations
    localparam int FAULT_ADDR = 2;        // which weight gets the SEU
    localparam int FAULT_BIT  = 5;        // codeword bit to flip (single-bit)

    integer j;
    logic signed [18:0] golden_res, off_res, on_res;
    logic [31:0] scrub_after, ecc_after;
    logic [12:0] cw;

    // Extract the 8 *uncorrected* data bits from a 13-bit codeword
    // (data bit positions per ecc_secded: D1=2,D2=4,D3=5,D4=6,D5=8,D6=9,D7=10,D8=11)
    function automatic logic signed [7:0] raw_data(input logic [12:0] c);
        raw_data = {c[11], c[10], c[9], c[8], c[6], c[5], c[4], c[2]};
    endfunction

    // Write one weight (SECDED-encoded) to weight_mem_ecc
    task automatic wmem_write(input [14:0] a, input logic signed [7:0] d);
        @(posedge clock); #1;
        wr_en = 1; wr_addr = a; wr_data = d;
        @(posedge clock); #1;
        wr_en = 0;
    endtask

    // Read one weight via the ECC-corrected path; returns corrected data + status
    task automatic wmem_read(input [14:0] a,
                             output logic signed [7:0] d, output logic [1:0] st);
        rd_addr = a;
        @(posedge clock); #1;     // mem[a] -> rd_raw_reg; decode is combinational
        d  = rd_data;
        st = rd_error_status;
    endtask

    logic signed [7:0] vec [0:N-1];

    // Present weight row `vec` to the MAC and capture results[0]
    task automatic mac_eval(output logic signed [18:0] out0);
        for (j = 0; j < N; j++) begin
            weights[0][j] = vec[j];
            activations[j] = act[j];
        end
        @(posedge clock); #1;           // register results
        @(posedge clock); #1;
        out0 = results[0];
    endtask

    logic signed [7:0] dtmp; logic [1:0] sttmp;

    initial begin
        // init weights / activations
        gw[0]=10; gw[1]=-5; gw[2]=20; gw[3]=7; gw[4]=-3; gw[5]=15; gw[6]=0; gw[7]=12;
        act[0]=1; act[1]=2; act[2]=3; act[3]=4; act[4]=5; act[5]=6; act[6]=7; act[7]=8;
        for (j=0;j<N;j++) for (int k=0;k<N;k++) weights[j][k]=0;

        repeat (4) @(posedge clock);
        reset = 0;
        @(posedge clock);

        // Load the 8 weights (SECDED-encoded into weight_mem_ecc)
        for (j=0;j<N;j++) wmem_write(j[14:0], gw[j]);

        $display("============================================================");
        $display(" RAD-HARD-AI  —  ECC single-event-upset demo (real RTL)");
        $display("   weights = {10,-5,20,7,-3,15,0,12}  acts = {1..8}");
        $display("   SEU: flip bit %0d of stored codeword at weight addr %0d",
                 FAULT_BIT, FAULT_ADDR);
        $display("============================================================");

        // -------- A. NO FAULT --------------------------------------------
        for (j=0;j<N;j++) begin wmem_read(j[14:0], dtmp, sttmp); vec[j]=dtmp; end
        mac_eval(golden_res);
        $display("[A] no fault      : MAC result[0] = %0d   (GOLDEN)", golden_res);

        // -------- inject the SEU: flip one stored codeword bit -----------
        u_wmem.mem[FAULT_ADDR][FAULT_BIT] = ~u_wmem.mem[FAULT_ADDR][FAULT_BIT];
        $display("    >> injected single-bit flip into weight_mem_ecc.mem[%0d][%0d]",
                 FAULT_ADDR, FAULT_BIT);

        // -------- B. FAULT, ECC OFF (raw uncorrected data) ----------------
        for (j=0;j<N;j++) begin
            cw     = u_wmem.mem[j[14:0]][12:0];
            vec[j] = raw_data(cw);          // bypass correction
        end
        mac_eval(off_res);
        $display("[B] fault, ECC OFF: MAC result[0] = %0d   (corrupted, no counter)",
                 off_res);

        // -------- C. FAULT, ECC ON (decoder corrects + telemetry) ---------
        for (j=0;j<N;j++) begin
            wmem_read(j[14:0], dtmp, sttmp);
            vec[j] = dtmp;
            if (sttmp == 2'b01) begin       // single-bit corrected -> telemetry
                scrub_corrections_inc = 1;
                event_push = 1; event_type = 2'd0;            // 0 = scrub_correct
                event_addr = j[15:0]; event_timestamp = 14'd1;
                @(posedge clock); #1;
                scrub_corrections_inc = 0; event_push = 0;
            end
        end
        mac_eval(on_res);
        $display("[C] fault, ECC ON : MAC result[0] = %0d   (corrected)", on_res);

        // read telemetry counters
        reg_addr = 8'h10; reg_rd_en = 1; @(posedge clock); #1; reg_rd_en = 0;
        @(posedge clock); #1; scrub_after = reg_rd_data;
        reg_addr = 8'h14; reg_rd_en = 1; @(posedge clock); #1; reg_rd_en = 0;
        @(posedge clock); #1; ecc_after = reg_rd_data;

        $display("------------------------------------------------------------");
        $display(" telemetry: scrub_corrections = %0d   ecc_double_errors = %0d",
                 scrub_after, ecc_after);
        $display("------------------------------------------------------------");

        if (golden_res !== off_res &&
            on_res === golden_res &&
            scrub_after == 32'd1) begin
            $display(" DEMO PASS: ECC OFF corrupts output (%0d != %0d); ECC ON",
                     off_res, golden_res);
            $display("            restores it (%0d) and logs 1 correction.",
                     on_res);
        end else begin
            $display(" DEMO FAIL: golden=%0d off=%0d on=%0d scrub=%0d",
                     golden_res, off_res, on_res, scrub_after);
        end
        $display("============================================================");
        $finish;
    end

endmodule : tb_ecc_demo
