// =============================================================================
// weight_loader.sv
// Weight matrix loader — sequences weight_mem reads into mac_array format
//
// Description:
//   On a single-cycle 'start' pulse (sampled while in IDLE), the loader
//   sequences read addresses 0..63 to weight_mem's read port and stores
//   each returned 8-bit signed value into the corresponding position of an
//   internal 8x8 register array using row-major addressing:
//
//       addr = row * 8 + col   =>   weights_reg[row][col]
//
//   The loaded array is continuously driven out as 'weights_out', which
//   connects directly to mac_array's 'weights' input port.
//
//   A 'done' pulse (one cycle wide) is asserted once all 64 entries are
//   loaded and the state machine returns to IDLE.
//
// Timing (weight_mem has 1-cycle registered read latency):
//
//   weight_mem's rd_data at posedge X  = mem[ rd_addr before posedge X-1 ]
//
//   The loader presents rd_addr = addr_ctr combinationally.  Due to the
//   registered read, data for address k becomes visible to the loader two
//   posedges after the address is first presented.  This is handled by
//   capturing rd_data when addr_ctr >= 1 and storing it at position
//   (addr_ctr - 1).
//
//   Loading timeline from the posedge where start is sampled (posedge T):
//     T+0  : state→LOADING, addr_ctr=0, weight_mem latches rd_addr=0
//     T+1  : addr_ctr=0, weight_mem latches rd_addr=0 again (no capture yet)
//     T+2  : addr_ctr=1, rd_data=mem[0] → weights_reg[0][0]
//     T+3  : addr_ctr=2, rd_data=mem[1] → weights_reg[0][1]
//     ...
//     T+65 : addr_ctr=64, rd_data=mem[63] → weights_reg[7][7]; →DONE_ST
//     T+66 : DONE_ST — done=1; →IDLE
//
// =============================================================================

module weight_loader (
    input  logic                    clock,
    input  logic                    reset,

    // Control
    input  logic                    start,      // Single-cycle start pulse
    output logic                    done,       // Single-cycle done pulse

    // weight_mem read interface
    output logic        [5:0]       rd_addr,
    input  logic signed [7:0]       rd_data,

    // Loaded weight array — drives mac_array weights input directly
    output logic signed [7:0]       weights_out [0:7][0:7]
);

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        IDLE    = 2'b00,
        LOADING = 2'b01,
        DONE_ST = 2'b10
    } state_t;

    state_t              state;

    // 7-bit counter: 0..64 (inclusive)
    logic [6:0]          addr_ctr;

    // Internal weight register array
    logic signed [7:0]   weights_reg [0:7][0:7];

    // -------------------------------------------------------------------------
    // Capture index: (addr_ctr - 1), valid when addr_ctr >= 1
    // Upper 3 bits = row (addr / 8), lower 3 bits = col (addr % 8)
    // -------------------------------------------------------------------------
    logic [5:0]          cap_idx;
    always_comb cap_idx = 6'(addr_ctr - 7'd1);

    // -------------------------------------------------------------------------
    // rd_addr: combinational — presents current address counter to weight_mem
    // Clamped to 0 once addr_ctr exceeds the valid address range
    // -------------------------------------------------------------------------
    always_comb begin
        if (state == LOADING && addr_ctr <= 7'd63) begin
            rd_addr = addr_ctr[5:0];
        end else begin
            rd_addr = 6'd0;
        end
    end

    // -------------------------------------------------------------------------
    // Continuous output of loaded weight array
    // -------------------------------------------------------------------------
    assign weights_out = weights_reg;

    // -------------------------------------------------------------------------
    // FSM + weight capture registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset) begin
            state    <= IDLE;
            addr_ctr <= 7'd0;
            done     <= 1'b0;
            for (int i = 0; i < 8; i++) begin
                for (int j = 0; j < 8; j++) begin
                    weights_reg[i][j] <= 8'sd0;
                end
            end
        end else begin
            done <= 1'b0;   // default: deassert each cycle

            case (state)

                // ----------------------------------------------------------
                IDLE: begin
                    if (start) begin
                        state    <= LOADING;
                        addr_ctr <= 7'd0;
                    end
                end

                // ----------------------------------------------------------
                LOADING: begin
                    // Capture rd_data into the register array.
                    // weight_mem's 1-cycle latency means rd_data now holds
                    // the result for address (addr_ctr - 1).
                    if (addr_ctr >= 7'd1) begin
                        weights_reg[cap_idx[5:3]][cap_idx[2:0]] <= rd_data;
                    end

                    // Advance address counter (hold at 64 after last entry)
                    if (addr_ctr < 7'd64) begin
                        addr_ctr <= addr_ctr + 7'd1;
                    end

                    // All 64 entries captured — transition to done pulse
                    if (addr_ctr == 7'd64) begin
                        state <= DONE_ST;
                    end
                end

                // ----------------------------------------------------------
                DONE_ST: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                // ----------------------------------------------------------
                default: state <= IDLE;

            endcase
        end
    end

endmodule : weight_loader
