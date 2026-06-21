// =============================================================================
// fault_replay.sv
// Simulation-only fault injection module — reads a schedule from a text file
// and performs bit-flip injections into target memory arrays at specified
// simulation cycles via hierarchical reference.
//
// File format (one line per event):
//   <cycle> <mem_id> <addr> <bit_idx>
//   All fields are unsigned decimal integers separated by whitespace.
//   Example:
//     10  0  5  3    # at cycle 10, flip bit 3 of mem_id-0 word at addr 5
//
// mem_id mapping (testbench-topology-specific, see NOTE below):
//   0  →  weight_mem  :  logic signed [7:0] mem [0:63]
//   1  →  act_mem     :  placeholder — logs warning when triggered
//
// NOTE: The hierarchical paths used for memory access are hardcoded for the
//       companion testbench tb_fault_replay.  When reusing this module,
//       update the case-statement paths to match your own hierarchy.
//       Specifically:
//         mem_id 0  →  $root.tb_fault_replay.u_weight_mem.mem[addr]
//         mem_id 1  →  $root.tb_fault_replay.u_act_mem.mem[addr]
//
// Cycle counter behaviour:
//   cycle_count is held at 0 during reset and increments each posedge once
//   reset deasserts.  Injection fires at the posedge where cycle_count
//   (before increment) equals the scheduled cycle value.
//
// File read timing:
//   The initial block waits #1 time unit before opening the file so that a
//   testbench initial block writing the file at t=0 completes first.
// =============================================================================

module fault_replay #(
    parameter string FAULT_FILE = "faults.txt",  // path to fault schedule
    parameter int    MAX_EVENTS = 256             // maximum events supported
) (
    input logic clock,
    input logic reset
);

    // =========================================================================
    // Fault event record
    // =========================================================================
    typedef struct {
        int unsigned cycle;
        int unsigned mem_id;
        int unsigned addr;
        int unsigned bit_idx;
    } fault_event_t;

    fault_event_t    events [0:MAX_EVENTS-1];
    int unsigned     num_events;

    // =========================================================================
    // Cycle counter
    // =========================================================================
    longint unsigned cycle_count;

    always_ff @(posedge clock) begin
        if (reset) cycle_count <= '0;
        else       cycle_count <= cycle_count + 1;
    end

    // =========================================================================
    // File read — deferred 1 time unit to allow testbench to write the file
    // =========================================================================
    initial begin
        automatic integer     fd;
        automatic integer     scan_result;
        automatic int unsigned cyc, mid, adr, bidx;

        num_events = 0;
        #1;  // wait for testbench initial block to finish writing the file

        fd = $fopen(FAULT_FILE, "r");
        if (fd == 0) begin
            $display("FAULT_REPLAY: ERROR: cannot open fault file '%s'", FAULT_FILE);
        end else begin
            scan_result = $fscanf(fd, "%d %d %d %d", cyc, mid, adr, bidx);
            while (scan_result == 4) begin
                if (num_events < MAX_EVENTS) begin
                    events[num_events].cycle   = cyc;
                    events[num_events].mem_id  = mid;
                    events[num_events].addr    = adr;
                    events[num_events].bit_idx = bidx;
                    num_events++;
                end else begin
                    $display("FAULT_REPLAY: WARNING: MAX_EVENTS=%0d exceeded, skipping remaining lines",
                             MAX_EVENTS);
                end
                scan_result = $fscanf(fd, "%d %d %d %d", cyc, mid, adr, bidx);
            end
            $fclose(fd);
            $display("FAULT_REPLAY: loaded %0d fault event(s) from '%s'",
                     num_events, FAULT_FILE);
        end
    end

    // =========================================================================
    // Fault injection — fires when cycle_count (before posedge) matches event
    // =========================================================================
    always @(posedge clock) begin
        if (!reset) begin
            for (int i = 0; i < int'(num_events); i++) begin
                if (cycle_count == longint'(events[i].cycle)) begin

                    $display("FAULT_REPLAY: t=%0t  cycle=%0d  mem_id=%0d  addr=%0d  bit=%0d  — BIT FLIP INJECTED",
                             $time, cycle_count,
                             events[i].mem_id, events[i].addr, events[i].bit_idx);

                    // ----------------------------------------------------------
                    // Perform the bit flip via hierarchical reference.
                    // XOR the full word with a single-bit mask so only
                    // bit[bit_idx] is toggled.
                    // ----------------------------------------------------------
                    case (events[i].mem_id)

                        0: begin
                            // weight_mem — logic signed [7:0] mem [0:63]
                            // Hierarchical path: tb_fault_replay → u_weight_mem → mem
                            tb_fault_replay.u_weight_mem.mem[events[i].addr] =
                                tb_fault_replay.u_weight_mem.mem[events[i].addr] ^
                                (8'b1 << events[i].bit_idx[2:0]);
                        end

                        1: begin
                            // act_mem — placeholder (not yet implemented)
                            $display("FAULT_REPLAY: mem_id=1 (act_mem) not yet instantiated — skipping");
                        end

                        default: begin
                            $display("FAULT_REPLAY: unknown mem_id=%0d — skipping", events[i].mem_id);
                        end

                    endcase
                end
            end
        end
    end

endmodule : fault_replay
