// =============================================================================
// accel_top.sv
// Top-level integration: weight_mem + weight_loader + mac_array
//
// Description:
//   Exposes a host-facing write interface for weight_mem preloading, a
//   start/done handshake for the weight-load sequence, an 8-element INT8
//   activation input, and an 8-element 19-bit signed MAC result output.
//
//   Internal data path:
//     host  ──(wr_en/wr_addr/wr_data)──► weight_mem
//     weight_loader ──rd_addr──► weight_mem ──rd_data──► weight_loader
//     weight_loader.weights_out ──► mac_array.weights
//     activations               ──► mac_array.activations
//     mac_array.results         ──► results (top-level output)
//
// Done signal timing:
//   Posedge T−1 : weight_loader captures last weight (addr 63); acc_comb
//                 inside mac_array immediately reflects the complete matrix.
//   Posedge T   : weight_loader enters DONE_ST → loader_done=1;
//                 mac_array.results registers capture acc_comb.
//   Posedge T+1 : accel_top.done=1 (registered loader_done);
//                 mac_array.results have been stable since posedge T.
//
//   Total latency from start pulse to done: ~68 clock cycles.
//
// Ports:
//   clock, reset     — system clock and synchronous active-high reset
//   wr_en            — weight_mem write enable (host preload)
//   wr_addr [5:0]    — weight_mem write address (0..63, row-major)
//   wr_data [7:0]    — weight_mem write data (INT8 signed)
//   start            — single-cycle pulse: begin weight-load sequence
//   activations[7:0] — 8-element INT8 activation vector (combinational)
//   results[7:0]     — 8-element 19-bit signed MAC results (registered)
//   done             — single-cycle pulse when results are valid
// =============================================================================

module accel_top (
    input  logic                    clock,
    input  logic                    reset,

    // Host weight-memory write port
    input  logic                    wr_en,
    input  logic        [5:0]       wr_addr,
    input  logic signed [7:0]       wr_data,

    // Control
    input  logic                    start,
    output logic                    done,

    // Activation input (held stable by host during and after start)
    input  logic signed [7:0]       activations [0:7],

    // MAC result output (valid when done pulses and held until next start)
    output logic signed [18:0]      results     [0:7]
);

    // -------------------------------------------------------------------------
    // Internal wires
    // -------------------------------------------------------------------------
    logic        [5:0]      rd_addr;
    logic signed [7:0]      rd_data;
    logic signed [7:0]      weights_int [0:7][0:7];
    logic                   loader_done;

    // -------------------------------------------------------------------------
    // weight_mem — 64-entry INT8 SRAM
    // -------------------------------------------------------------------------
    weight_mem u_weight_mem (
        .clock   (clock),
        .reset   (reset),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    // -------------------------------------------------------------------------
    // weight_loader — sequences weight_mem reads into 8x8 register array
    // -------------------------------------------------------------------------
    weight_loader u_weight_loader (
        .clock       (clock),
        .reset       (reset),
        .start       (start),
        .done        (loader_done),
        .rd_addr     (rd_addr),
        .rd_data     (rd_data),
        .weights_out (weights_int)
    );

    // -------------------------------------------------------------------------
    // mac_array — 8x8 systolic INT8 multiply-accumulate array
    // -------------------------------------------------------------------------
    mac_array u_mac_array (
        .clock       (clock),
        .reset       (reset),
        .weights     (weights_int),
        .activations (activations),
        .results     (results)
    );

    // -------------------------------------------------------------------------
    // done — registered one cycle after loader_done to guarantee
    // mac_array.results have been captured by their output FF
    // -------------------------------------------------------------------------
    always_ff @(posedge clock) begin
        if (reset) begin
            done <= 1'b0;
        end else begin
            done <= loader_done;
        end
    end

endmodule : accel_top
