// =============================================================================
// tb_weight_mem_ecc.sv
// Testbench for weight_mem_ecc — ECC-protected 32K×8 weight SRAM
//
// Test plan:
//   PHASE 1 — Write & read-back at spread addresses (no errors injected):
//     addr 0x00000 : 8'hAA  (address 0, near bottom)
//     addr 0x00001 : 8'h55  (address 1)
//     addr 0x00064 : 8'hF0  (address 100, mid-low)
//     addr 0x03FFF : 8'h0F  (address 16383, middle of range)
//     addr 0x07FFE : 8'h01  (address 32766, near top)
//     addr 0x07FFF : 8'hFF  (address 32767, top of range)
//
//   PHASE 2 — Reset output register check (rd_data = 0 after reset)
//
//   PHASE 3 — ECC correction with injected single-bit error:
//     Write 8'hAC to address 0x00032 (=50 decimal)
//     Wait for write to settle
//     Directly corrupt bit 5 of the stored word (dut.mem[50][5]) via
//     hierarchical reference — simulates an SRAM cell upset
//     Read back: expect rd_data = 8'hAC (corrected), rd_error_status = 2'b01
// =============================================================================

module tb_weight_mem_ecc;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                   clock;
    logic                   reset;
    logic                   wr_en;
    logic [14:0]            wr_addr;
    logic signed [7:0]      wr_data;
    logic [14:0]            rd_addr;
    logic signed [7:0]      rd_data;
    logic [1:0]             rd_error_status;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    weight_mem_ecc dut (
        .clock          (clock),
        .reset          (reset),
        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .rd_addr        (rd_addr),
        .rd_data        (rd_data),
        .rd_error_status(rd_error_status)
    );

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period
    // -------------------------------------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #10000;
        $fatal(1, "TIMEOUT: simulation exceeded safety limit");
    end

    // -------------------------------------------------------------------------
    // Test addresses and data values
    // -------------------------------------------------------------------------
    // 6 address/data pairs spanning bottom, low, mid-low, middle, near-top, top
    localparam int NUM_PAIRS = 6;

    logic [14:0] test_addr [NUM_PAIRS];
    logic signed [7:0] test_data [NUM_PAIRS];

    // -------------------------------------------------------------------------
    // Fail counter
    // -------------------------------------------------------------------------
    integer fail_count;

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("TEST START");
        fail_count = 0;

        // Populate test vectors
        test_addr[0] = 15'h0000;  test_data[0] = 8'hAA;  // addr   0 — bottom
        test_addr[1] = 15'h0001;  test_data[1] = 8'h55;  // addr   1
        test_addr[2] = 15'h0064;  test_data[2] = 8'hF0;  // addr 100
        test_addr[3] = 15'h3FFF;  test_data[3] = 8'h0F;  // addr 16383 — middle
        test_addr[4] = 15'h7FFE;  test_data[4] = 8'h01;  // addr 32766 — near top
        test_addr[5] = 15'h7FFF;  test_data[5] = 8'hFF;  // addr 32767 — top

        // ------------------------------------------------------------------
        // Reset
        // ------------------------------------------------------------------
        reset   = 1'b1;
        wr_en   = 1'b0;
        wr_addr = 15'h0000;
        wr_data = 8'sh00;
        rd_addr = 15'h0000;

        @(posedge clock); #1;
        @(posedge clock); #1;
        reset = 1'b0;

        // ------------------------------------------------------------------
        // PHASE 2 — Reset check: rd_data and rd_error_status clear after reset
        // ------------------------------------------------------------------
        @(posedge clock); #1;  // one more cycle to let rd register settle after reset
        if (rd_data !== 8'sh00 || rd_error_status !== 2'b00) begin
            $display("LOG: %0t : ERROR : tb_weight_mem_ecc : RESET_CHECK : rd_data=%0h rd_error_status=%02b",
                     $time, rd_data, rd_error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_weight_mem_ecc : RESET_CHECK : rd_data=00 rd_error_status=00  OK",
                     $time);
        end

        // ------------------------------------------------------------------
        // PHASE 1 — Write all test addresses
        // ------------------------------------------------------------------
        $display("--- Write phase ---");
        wr_en = 1'b1;
        for (int i = 0; i < NUM_PAIRS; i++) begin
            wr_addr = test_addr[i];
            wr_data = test_data[i];
            @(posedge clock); #1;
        end
        wr_en = 1'b0;

        // ------------------------------------------------------------------
        // PHASE 1 — Read-back all test addresses (1-cycle read latency)
        // ------------------------------------------------------------------
        $display("--- Read-back phase ---");

        // Pre-load first address
        rd_addr = test_addr[0];
        @(posedge clock); #1;  // rd_raw_reg now holds mem[test_addr[0]]

        for (int i = 1; i < NUM_PAIRS; i++) begin
            // Check data for address i-1 (available now)
            if (rd_data !== test_data[i-1] || rd_error_status !== 2'b00) begin
                $display("LOG: %0t : ERROR : tb_weight_mem_ecc : RD_addr_%0h : exp=%0h got=%0h status=%02b",
                         $time, test_addr[i-1], test_data[i-1], rd_data, rd_error_status);
                fail_count++;
            end else begin
                $display("LOG: %0t : INFO  : tb_weight_mem_ecc : RD_addr_%0h : data=%0h status=%02b  OK",
                         $time, test_addr[i-1], rd_data, rd_error_status);
            end
            // Present next address
            rd_addr = test_addr[i];
            @(posedge clock); #1;
        end

        // Check final address (NUM_PAIRS - 1)
        if (rd_data !== test_data[NUM_PAIRS-1] || rd_error_status !== 2'b00) begin
            $display("LOG: %0t : ERROR : tb_weight_mem_ecc : RD_addr_%0h : exp=%0h got=%0h status=%02b",
                     $time, test_addr[NUM_PAIRS-1], test_data[NUM_PAIRS-1], rd_data, rd_error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_weight_mem_ecc : RD_addr_%0h : data=%0h status=%02b  OK",
                     $time, test_addr[NUM_PAIRS-1], rd_data, rd_error_status);
        end

        // ------------------------------------------------------------------
        // PHASE 3 — ECC correction: inject a single-bit upset into stored word
        //
        // Write 8'hAC to address 50 (0x0032).
        // Then corrupt bit 5 of dut.mem[50] (which holds the 16-bit word
        // containing the 13-bit SECDED codeword in bits [12:0]).
        // Bit 5 of the codeword = codeword position 6 = D3.
        // Expected:
        //   - rd_data         = 8'hAC   (corrected by ECC decoder)
        //   - rd_error_status = 2'b01   (single-bit error corrected)
        // ------------------------------------------------------------------
        $display("--- ECC correction test (single-bit upset injection) ---");

        // Write 8'hAC to address 50
        wr_en   = 1'b1;
        wr_addr = 15'd50;
        wr_data = 8'shAC;
        @(posedge clock); #1;
        wr_en = 1'b0;

        // Allow write to settle, then flip bit 5 of stored word at addr 50
        // (hierarchical force on the SRAM array cell)
        #1;
        dut.mem[50][5] = ~dut.mem[50][5];

        // Read from address 50 (1-cycle latency)
        rd_addr = 15'd50;
        @(posedge clock); #1;

        if (rd_data !== 8'shAC || rd_error_status !== 2'b01) begin
            $display("LOG: %0t : ERROR : tb_weight_mem_ecc : ECC_CORRECT : exp=AC/01 got=%0h/%02b",
                     $time, rd_data, rd_error_status);
            fail_count++;
        end else begin
            $display("LOG: %0t : INFO  : tb_weight_mem_ecc : ECC_CORRECT : data=%0h rd_error_status=%02b  OK",
                     $time, rd_data, rd_error_status);
        end

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("weight_mem_ecc testbench: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end

        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("weight_mem_ecc.fst");
        $dumpvars(0);
    end

endmodule : tb_weight_mem_ecc
