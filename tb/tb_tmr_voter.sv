// =============================================================================
// tb_tmr_voter.sv
// Unit testbench for tmr_voter.sv
//
// =============================================================================
// TEST CASES
// =============================================================================
//
//   WIDTH=8 for compact, human-readable checks.
//
//   Case 1 — All agree (no fault):
//     in_a = in_b = in_c = 0xA5
//     Expected: voted_out = 0xA5, disagreement = 0
//
//   Case 2 — Input A differs (single-voter fault):
//     in_a = 0x00, in_b = in_c = 0xA5
//     Expected: voted_out = 0xA5 (B and C majority), disagreement = 1
//
//   Case 3 — Input B differs:
//     in_b = 0xFF, in_a = in_c = 0xA5
//     Expected: voted_out = 0xA5 (A and C majority), disagreement = 1
//
//   Case 4 — Input C differs:
//     in_c = 0x00, in_a = in_b = 0xA5
//     Expected: voted_out = 0xA5 (A and B majority), disagreement = 1
//
//   Case 5 — All zeros (boundary):
//     in_a = in_b = in_c = 0x00
//     Expected: voted_out = 0x00, disagreement = 0
//
//   Case 6 — All ones:
//     in_a = in_b = in_c = 0xFF
//     Expected: voted_out = 0xFF, disagreement = 0
//
//   Case 7 — Per-bit split: A and B agree per bit, C is bitwise complement:
//     in_a = in_b = 0xF0, in_c = 0x0F
//     Per bit: upper nibble A=1,B=1,C=0 -> voted=1; lower nibble A=0,B=0,C=1 -> voted=0
//     Expected: voted_out = 0xF0, disagreement = 1
//
// =============================================================================

module tb_tmr_voter;

    localparam int WIDTH = 8;

    logic [WIDTH-1:0] in_a, in_b, in_c;
    logic [WIDTH-1:0] voted_out;
    logic             disagreement;

    tmr_voter #(.WIDTH(WIDTH)) dut (.*);

    integer fail_count;

    task automatic chk(
        input logic [WIDTH-1:0] actual_v,
        input logic [WIDTH-1:0] expected_v,
        input logic             actual_d,
        input logic             expected_d,
        input string            msg
    );
        logic ok;
        ok = (actual_v === expected_v) && (actual_d === expected_d);
        if (!ok) begin
            $display("LOG: %0t : ERROR : tb_tmr_voter : %s", $time, msg);
            if (actual_v !== expected_v)
                $display("         voted_out : expected=0x%02X actual=0x%02X",
                         expected_v, actual_v);
            if (actual_d !== expected_d)
                $display("         disagreement: expected=%0b actual=%0b",
                         expected_d, actual_d);
            fail_count++;
        end else
            $display("LOG: %0t : INFO  : tb_tmr_voter : %s  OK", $time, msg);
    endtask

    initial begin
        $display("TEST START");
        fail_count = 0;

        // ------------------------------------------------------------------
        // Case 1: all agree
        // ------------------------------------------------------------------
        in_a = 8'hA5; in_b = 8'hA5; in_c = 8'hA5; #1;
        chk(voted_out, 8'hA5, disagreement, 1'b0, "all_agree: voted=0xA5, no disagree");

        // ------------------------------------------------------------------
        // Case 2: A is the odd one out
        // ------------------------------------------------------------------
        in_a = 8'h00; in_b = 8'hA5; in_c = 8'hA5; #1;
        chk(voted_out, 8'hA5, disagreement, 1'b1, "A_differs: majority=0xA5, disagree=1");

        // ------------------------------------------------------------------
        // Case 3: B is the odd one out
        // ------------------------------------------------------------------
        in_a = 8'hA5; in_b = 8'hFF; in_c = 8'hA5; #1;
        chk(voted_out, 8'hA5, disagreement, 1'b1, "B_differs: majority=0xA5, disagree=1");

        // ------------------------------------------------------------------
        // Case 4: C is the odd one out
        // ------------------------------------------------------------------
        in_a = 8'hA5; in_b = 8'hA5; in_c = 8'h00; #1;
        chk(voted_out, 8'hA5, disagreement, 1'b1, "C_differs: majority=0xA5, disagree=1");

        // ------------------------------------------------------------------
        // Case 5: all zeros
        // ------------------------------------------------------------------
        in_a = 8'h00; in_b = 8'h00; in_c = 8'h00; #1;
        chk(voted_out, 8'h00, disagreement, 1'b0, "all_zeros: voted=0x00, no disagree");

        // ------------------------------------------------------------------
        // Case 6: all ones
        // ------------------------------------------------------------------
        in_a = 8'hFF; in_b = 8'hFF; in_c = 8'hFF; #1;
        chk(voted_out, 8'hFF, disagreement, 1'b0, "all_ones:  voted=0xFF, no disagree");

        // ------------------------------------------------------------------
        // Case 7: per-bit split -- C is the bitwise complement of A and B
        // ------------------------------------------------------------------
        in_a = 8'hF0; in_b = 8'hF0; in_c = 8'h0F; #1;
        chk(voted_out, 8'hF0, disagreement, 1'b1,
            "A=B=0xF0,C=0x0F: majority=0xF0, disagree=1");

        // ------------------------------------------------------------------
        // Final verdict
        // ------------------------------------------------------------------
        if (fail_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("ERROR");
            $error("tmr_voter: %0d check(s) failed", fail_count);
            $fatal(1, "Simulation terminated with failures");
        end
        $finish;
    end

    initial begin
        $dumpfile("tmr_voter.fst");
        $dumpvars(0);
    end

endmodule : tb_tmr_voter
