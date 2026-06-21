// =============================================================================
// ecc_secded.sv
// SECDED (Single-Error Correcting, Double-Error Detecting) Hamming codec
// 8-bit data → 13-bit codeword  (4 Hamming parity + 1 overall parity)
//
// Codeword position layout (1-indexed):
//   Pos:  1   2   3   4   5   6   7   8   9  10  11  12  13
//   Bit: P1  P2  D1  P4  D2  D3  D4  P8  D5  D6  D7  D8  P_all
//
// Port data bit mapping: data_in[0]=D1, data_in[1]=D2, …, data_in[7]=D8
// Codeword bit mapping : codeword[k-1] = bit at 1-indexed position k
//
// Standard Hamming parity coverage (each Pk covers positions where bit k=1):
//   P1  covers {3,5,7,9,11}  ↔ {D1,D2,D4,D5,D7}
//   P2  covers {3,6,7,10,11} ↔ {D1,D3,D4,D6,D7}
//   P4  covers {5,6,7,12}    ↔ {D2,D3,D4,D8}
//   P8  covers {9,10,11,12}  ↔ {D5,D6,D7,D8}
//   P_all = even parity over positions 1-12
//
// NOTE — specification discrepancies resolved here:
//   (a) Spec stated P1=D1^D2^D4^D6^D8 and P2=D1^D3^D4^D7.  These deviate
//       from standard Hamming coverage and would produce incorrect syndromes.
//       Standard equations are used so that syndrome={S8,S4,S2,S1} directly
//       encodes the 1-indexed position of any single-bit error.
//   (b) Spec described a "3-bit syndrome" but positions 1-13 require 4 bits;
//       syndrome is implemented as 4'b{S8,S4,S2,S1}.
//
// 4-bit syndrome decision logic:
//   syndrome=0 , overall_error=0 → no error                 (status=00)
//   syndrome=0 , overall_error=1 → P_all-bit-only error,    (status=00)
//                                   data bits are valid
//   syndrome≠0 , overall_error=1 → single-bit error at      (status=01)
//                                   position 'syndrome', corrected
//   syndrome≠0 , overall_error=0 → double-bit uncorrectable (status=10)
// =============================================================================

module ecc_secded (
    // -------------------------------------------------------------------------
    // Encoder
    // -------------------------------------------------------------------------
    input  logic [7:0]  data_in,        // 8-bit data to encode
    output logic [12:0] codeword_out,   // 13-bit SECDED codeword

    // -------------------------------------------------------------------------
    // Decoder
    // -------------------------------------------------------------------------
    input  logic [12:0] codeword_in,    // 13-bit received codeword
    output logic [7:0]  data_corrected, // Corrected 8-bit data output
    output logic [1:0]  error_status    // 00=none, 01=corrected, 10=uncorrectable
);

    // =========================================================================
    // ENCODER
    // =========================================================================

    // Named data bits from data_in
    logic enc_d1, enc_d2, enc_d3, enc_d4, enc_d5, enc_d6, enc_d7, enc_d8;
    assign enc_d1 = data_in[0];
    assign enc_d2 = data_in[1];
    assign enc_d3 = data_in[2];
    assign enc_d4 = data_in[3];
    assign enc_d5 = data_in[4];
    assign enc_d6 = data_in[5];
    assign enc_d7 = data_in[6];
    assign enc_d8 = data_in[7];

    // Hamming parity bits (even parity within each coverage group)
    logic enc_p1, enc_p2, enc_p4, enc_p8, enc_pall;
    assign enc_p1   = enc_d1 ^ enc_d2 ^ enc_d4 ^ enc_d5 ^ enc_d7; // pos 3,5,7,9,11
    assign enc_p2   = enc_d1 ^ enc_d3 ^ enc_d4 ^ enc_d6 ^ enc_d7; // pos 3,6,7,10,11
    assign enc_p4   = enc_d2 ^ enc_d3 ^ enc_d4 ^ enc_d8;           // pos 5,6,7,12
    assign enc_p8   = enc_d5 ^ enc_d6 ^ enc_d7 ^ enc_d8;           // pos 9,10,11,12
    assign enc_pall = enc_p1  ^ enc_p2  ^ enc_d1 ^ enc_p4  ^
                      enc_d2  ^ enc_d3  ^ enc_d4 ^ enc_p8  ^
                      enc_d5  ^ enc_d6  ^ enc_d7 ^ enc_d8;

    // Assemble codeword — codeword_out[pos-1] = bit at 1-indexed position pos
    assign codeword_out[0]  = enc_p1;   // pos  1
    assign codeword_out[1]  = enc_p2;   // pos  2
    assign codeword_out[2]  = enc_d1;   // pos  3
    assign codeword_out[3]  = enc_p4;   // pos  4
    assign codeword_out[4]  = enc_d2;   // pos  5
    assign codeword_out[5]  = enc_d3;   // pos  6
    assign codeword_out[6]  = enc_d4;   // pos  7
    assign codeword_out[7]  = enc_p8;   // pos  8
    assign codeword_out[8]  = enc_d5;   // pos  9
    assign codeword_out[9]  = enc_d6;   // pos 10
    assign codeword_out[10] = enc_d7;   // pos 11
    assign codeword_out[11] = enc_d8;   // pos 12
    assign codeword_out[12] = enc_pall; // pos 13

    // =========================================================================
    // DECODER
    // =========================================================================

    // Extract named bits from incoming codeword
    logic dec_p1, dec_p2, dec_d1, dec_p4, dec_d2, dec_d3, dec_d4;
    logic dec_p8, dec_d5, dec_d6, dec_d7, dec_d8, dec_pall;

    assign dec_p1   = codeword_in[0];
    assign dec_p2   = codeword_in[1];
    assign dec_d1   = codeword_in[2];
    assign dec_p4   = codeword_in[3];
    assign dec_d2   = codeword_in[4];
    assign dec_d3   = codeword_in[5];
    assign dec_d4   = codeword_in[6];
    assign dec_p8   = codeword_in[7];
    assign dec_d5   = codeword_in[8];
    assign dec_d6   = codeword_in[9];
    assign dec_d7   = codeword_in[10];
    assign dec_d8   = codeword_in[11];
    assign dec_pall = codeword_in[12];

    // Recompute parity checks from received data bits
    logic p1_chk, p2_chk, p4_chk, p8_chk;
    assign p1_chk = dec_d1 ^ dec_d2 ^ dec_d4 ^ dec_d5 ^ dec_d7;
    assign p2_chk = dec_d1 ^ dec_d3 ^ dec_d4 ^ dec_d6 ^ dec_d7;
    assign p4_chk = dec_d2 ^ dec_d3 ^ dec_d4 ^ dec_d8;
    assign p8_chk = dec_d5 ^ dec_d6 ^ dec_d7 ^ dec_d8;

    // Syndrome bits: computed XOR stored parity
    logic s1, s2, s4, s8;
    assign s1 = p1_chk ^ dec_p1;
    assign s2 = p2_chk ^ dec_p2;
    assign s4 = p4_chk ^ dec_p4;
    assign s8 = p8_chk ^ dec_p8;

    // 4-bit syndrome: value = 1-indexed position of single-bit error (0 = no error)
    logic [3:0] syndrome;
    assign syndrome = {s8, s4, s2, s1};

    // Overall parity: XOR of all 13 bits (or equivalently recompute over pos1-12
    // and compare to stored P_all)
    logic pall_chk, overall_error;
    assign pall_chk    = dec_p1 ^ dec_p2 ^ dec_d1 ^ dec_p4  ^
                         dec_d2 ^ dec_d3 ^ dec_d4 ^ dec_p8  ^
                         dec_d5 ^ dec_d6 ^ dec_d7 ^ dec_d8;
    assign overall_error = pall_chk ^ dec_pall;

    // -------------------------------------------------------------------------
    // Bit correction
    // syndrome≠0 AND overall_error=1 → single-bit error; flip bit at
    // 0-indexed position (syndrome − 1).
    // All other cases → pass codeword_in through unchanged.
    // -------------------------------------------------------------------------
    logic [12:0] corrected_cw;
    always_comb begin
        corrected_cw = codeword_in;
        if (syndrome != 4'd0 && overall_error) begin
            corrected_cw = codeword_in ^ (13'd1 << (syndrome - 4'd1));
        end
    end

    // -------------------------------------------------------------------------
    // Extract 8 data bits from corrected codeword
    //   D1=pos3=bit2, D2=pos5=bit4, D3=pos6=bit5, D4=pos7=bit6
    //   D5=pos9=bit8, D6=pos10=bit9, D7=pos11=bit10, D8=pos12=bit11
    // -------------------------------------------------------------------------
    assign data_corrected = {corrected_cw[11],  // D8
                             corrected_cw[10],  // D7
                             corrected_cw[9],   // D6
                             corrected_cw[8],   // D5
                             corrected_cw[6],   // D4
                             corrected_cw[5],   // D3
                             corrected_cw[4],   // D2
                             corrected_cw[2]};  // D1

    // -------------------------------------------------------------------------
    // Error status
    // -------------------------------------------------------------------------
    always_comb begin
        unique case ({(syndrome != 4'd0), overall_error})
            2'b00:   error_status = 2'b00; // no error
            2'b01:   error_status = 2'b00; // P_all-bit error only; data valid
            2'b11:   error_status = 2'b01; // single-bit corrected
            2'b10:   error_status = 2'b10; // double-bit uncorrectable
            default: error_status = 2'b00;
        endcase
    end

endmodule : ecc_secded
