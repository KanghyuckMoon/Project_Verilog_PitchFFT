`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: harmonic_pitch_detector
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

// ============================================================
// Harmonic-aware chromatic pitch detector (C4..C5)
// 512-point FFT, Fs = 4000 Hz -> 7.8125 Hz/bin
//
// Fixes for low-note / octave errors:
//   1) Evaluate 13 NOTE CENTERS instead of every raw FFT bin.
//   2) Fundamental uses max(k-1,k,k+1), so energy split between
//      adjacent FFT bins does not suppress C4/C#4/F4 etc.
//   3) Normal notes use score = 2*F + H2 + H3/2.
//      C4 uses a split-bin fundamental estimate and excludes H2 from ranking.
//   4) Ranking stays peak-based (no broad local-energy bonus), so
//      neighboring semitones do not get artificially boosted.
//   5) A weak fundamental may still be accepted when harmonic
//      evidence is strong; if BOTH H2 and H3 exist, a lower
//      fundamental/score is allowed.
//   6) C5->C4 octave guard: balanced 33/34-bin subharmonic evidence
//      corrects piano C4 cases where the 2nd harmonic dominates at C5.
//   7) E4-only 87.5% acceptance threshold improves weak E4 detection
//      without changing thresholds for the other chromatic notes.
//
// Port interface is intentionally identical to the previous module,
// so pitch_fft_voice_top.v does NOT need to change.
// ============================================================
module harmonic_pitch_detector #(
    parameter integer FUND_LO          = 33, // kept for top compatibility
    parameter integer FUND_HI          = 68, // kept for top compatibility
    parameter [26:0] FUND_MIN          = 27'd240,
    parameter [26:0] HARM_MIN          = 27'd200,
    parameter [28:0] SCORE_MIN         = 29'd1400
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        fft_valid,
    input  wire        fft_last,
    input  wire [63:0] fft_data,

    output reg  [8:0]  fund_bin    = 9'd0,
    output reg  [26:0] fund_mag    = 27'd0,
    output reg  [26:0] second_mag  = 27'd0,
    output reg  [26:0] third_mag   = 27'd0,
    output reg  [1:0]  confidence  = 2'd0,
    output reg         second_ok   = 1'b0,
    output reg         third_ok    = 1'b0,
    output reg         pitch_valid = 1'b0,
    output reg         done        = 1'b0
);

    // 512-point, 16-bit fixed-point, unscaled FFT => 26-bit components.
    // AXI packing: real [25:0], imag [57:32].
    wire signed [25:0] re = fft_data[25:0];
    wire signed [25:0] im = fft_data[57:32];

    wire [25:0] abs_re = re[25] ? (~re + 26'd1) : re;
    wire [25:0] abs_im = im[25] ? (~im + 26'd1) : im;
    wire [26:0] mag = {1'b0, abs_re} + {1'b0, abs_im};

    // Need through about 3*C5 plus search margin (< 206).
    reg [26:0] spectrum [0:255];
    reg [8:0] fft_bin = 9'd0;

    // Rounded FFT-bin centers for C4..C5.
    // actual bins: 33.49,35.48,37.59,39.82,42.19,44.70,
    //              47.36,50.18,53.16,56.32,59.67,63.22,66.98
    function [8:0] note_center_bin;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  note_center_bin = 9'd33; // C4
                4'd1:  note_center_bin = 9'd35; // C#4
                4'd2:  note_center_bin = 9'd38; // D4
                4'd3:  note_center_bin = 9'd40; // D#4
                4'd4:  note_center_bin = 9'd42; // E4
                4'd5:  note_center_bin = 9'd45; // F4
                4'd6:  note_center_bin = 9'd47; // F#4
                4'd7:  note_center_bin = 9'd50; // G4
                4'd8:  note_center_bin = 9'd53; // G#4
                4'd9:  note_center_bin = 9'd56; // A4
                4'd10: note_center_bin = 9'd60; // A#4
                4'd11: note_center_bin = 9'd63; // B4
                default: note_center_bin = 9'd67; // C5
            endcase
        end
    endfunction

    localparam [2:0] ST_CAPTURE = 3'd0,
                     ST_READ    = 3'd1,
                     ST_PROCESS = 3'd2,
                     ST_EVAL    = 3'd3,
                     ST_REPORT  = 3'd4;

    reg [2:0] state = ST_CAPTURE;
    reg [3:0] cand_idx = 4'd0; // 0..12 = C4..C5
    wire [8:0] cand_bin = note_center_bin(cand_idx);
    wire [8:0] two_k   = cand_bin << 1;
    wire [8:0] three_k = cand_bin + (cand_bin << 1);

    // scan phases:
    //  0..2  : F  = k-1, k, k+1
    //  3..5  : H2 = 2k-1, 2k, 2k+1
    //  6..10 : H3 = 3k-2 .. 3k+2
    reg [3:0] scan_phase = 4'd0;
    reg [8:0] scan_addr;

    always @(*) begin
        case (scan_phase)
            4'd0:  scan_addr = cand_bin - 9'd1;
            4'd1:  scan_addr = cand_bin;
            4'd2:  scan_addr = cand_bin + 9'd1;
            4'd3:  scan_addr = two_k - 9'd1;
            4'd4:  scan_addr = two_k;
            4'd5:  scan_addr = two_k + 9'd1;
            4'd6:  scan_addr = three_k - 9'd2;
            4'd7:  scan_addr = three_k - 9'd1;
            4'd8:  scan_addr = three_k;
            4'd9:  scan_addr = three_k + 9'd1;
            default: scan_addr = three_k + 9'd2; // phase 10
        endcase
    end

    reg [26:0] rd_data = 27'd0;
    reg [26:0] cur_f    = 27'd0;
    reg [26:0] cur_h2   = 27'd0;
    reg [26:0] cur_h3   = 27'd0;

    reg [8:0]  best_bin   = 9'd0;
    reg [26:0] best_f     = 27'd0;
    reg [26:0] best_h2    = 27'd0;
    reg [26:0] best_h3    = 27'd0;
    reg [28:0] best_score = 29'd0;
    reg        best_found = 1'b0;

    // Remember C4 evidence for octave-error correction at report time.
    reg [26:0] c4_f     = 27'd0;
    reg [26:0] c4_h2    = 27'd0;
    reg [26:0] c4_h3    = 27'd0;
    reg [28:0] c4_score = 29'd0;
    // C4 is almost exactly halfway between FFT bins 33 and 34.
    // Keep those two bins separately for a conservative octave-error check.
    reg [26:0] c4_bin33 = 27'd0;
    reg [26:0] c4_bin34 = 27'd0;

    // ------------------------------------------------------------
    // C4-specific scoring
    // ------------------------------------------------------------
    // C4 = 261.63 Hz lies at FFT bin 33.49, so its fundamental is naturally
    // split across bins 33 and 34. Using only max(32,33,34) underestimates C4,
    // especially for piano tones whose 2nd harmonic near C5 can be very strong.
    //
    // Recover part of the split fundamental with:
    //     C4_F_EFF = max(bin33,bin34) + 0.5*min(bin33,bin34)
    // This boosts genuine C4 without simply doubling its score scale.
    //
    // IMPORTANT: C4's H2 is NOT added to its ranking score. H2 is kept only
    // as harmonic/octave evidence below, so a large 523-Hz piano harmonic does
    // not dominate the C4 ranking calculation.
    wire [27:0] c4_pair_sum = {1'b0, c4_bin33} + {1'b0, c4_bin34};
    wire [26:0] c4_pair_max = (c4_bin33 > c4_bin34) ? c4_bin33 : c4_bin34;
    wire [26:0] c4_pair_min = (c4_bin33 < c4_bin34) ? c4_bin33 : c4_bin34;
    wire [27:0] c4_f_eff = {1'b0, c4_pair_max} + ({1'b0, c4_pair_min} >> 1);

    wire [28:0] normal_score = {1'b0, cur_f, 1'b0}
                               + {2'b00, cur_h2}
                               + ({2'b00, cur_h3} >> 1);

    wire [28:0] c4_special_score = {c4_f_eff, 1'b0}
                                   + ({2'b00, cur_h3} >> 1);

    wire c4_candidate = (cand_idx == 4'd0);
    wire [28:0] cur_score = c4_candidate ? c4_special_score : normal_score;

    // E4-only 87.5% thresholds
    wire [26:0] e4_fund_min  = FUND_MIN  - (FUND_MIN  >> 3);
    wire [28:0] e4_score_min = SCORE_MIN - (SCORE_MIN >> 3);

    wire [26:0] weak_fund_min      = FUND_MIN >> 1; // 50%
    wire [26:0] very_weak_fund_min = FUND_MIN >> 2; // 25%

    wire cur_h2_present = (cur_h2 >= HARM_MIN);
    wire cur_h3_present = (cur_h3 >= HARM_MIN);
    wire cur_harm_present = cur_h2_present || cur_h3_present;
    wire cur_both_harm = cur_h2_present && cur_h3_present;

    // Keep the normal threshold for ordinary cases. Only C4 receives an
    // additional eligibility path based on its recovered split fundamental.
    wire e4_candidate = (cand_idx == 4'd4);
    wire c4_split_eligible = c4_candidate && (c4_f_eff >= FUND_MIN);

    wire cur_eligible =
        (cur_f >= FUND_MIN) ||
        ((cur_f >= weak_fund_min) && cur_harm_present) ||
        ((cur_f >= very_weak_fund_min) && cur_both_harm) ||
        c4_split_eligible ||
        (e4_candidate && (cur_f >= e4_fund_min));
    wire cur_better = cur_eligible && (!best_found || (cur_score > best_score));

    // C4 octave guard (ratio-based):
    // If C5 wins, inspect whether a real subharmonic exists at C4. This is the
    // key protection for piano C4, where 523 Hz may dominate during the attack.
    //
    // C4 is almost midway between bins 33 and 34, so both bins should carry
    // meaningful energy. Require the weaker bin to be at least 25% of the
    // stronger one.
    wire c4_pair_balanced =
        (c4_pair_max != 27'd0) &&
        (c4_pair_min >= (c4_pair_max >> 2));

    // Require the C4 pair to be at least 18.75% (= 1/8 + 1/16) of the winning
    // C5 fundamental. This is deliberately stronger than the previous 6.25%
    // test, so random low-frequency noise is less likely to pull a true C5 down.
    wire [27:0] c4_relative_floor =
        ({1'b0, best_f} >> 3) + ({1'b0, best_f} >> 4);
    wire c4_relative_present = (c4_pair_sum >= c4_relative_floor);

    // H2 is used only as evidence that the C4 harmonic relationship is present;
    // it no longer contributes to C4's ranking score.
    wire c4_octave_evidence =
        (c4_f_eff >= (FUND_MIN >> 2)) &&
        c4_pair_balanced &&
        c4_relative_present &&
        (c4_h2 >= HARM_MIN);

    wire use_c4_octave_fix = (best_bin == 9'd67) && c4_octave_evidence;

    wire [8:0] report_bin = use_c4_octave_fix ? 9'd33 : best_bin;
    wire [26:0] report_f  = use_c4_octave_fix ? c4_f : best_f;
    wire [26:0] report_h2 = use_c4_octave_fix ? c4_h2 : best_h2;
    wire [26:0] report_h3 = use_c4_octave_fix ? c4_h3 : best_h3;
    wire [28:0] report_score = use_c4_octave_fix ? c4_score : best_score;

    wire [26:0] rel_harm_min = report_f >> 4; // ~6.25% of fundamental
    wire [26:0] eff_harm_min = (rel_harm_min > HARM_MIN) ? rel_harm_min : HARM_MIN;
    wire report_h2_ok = (report_h2 >= eff_harm_min);
    wire report_h3_ok = (report_h3 >= eff_harm_min);
    wire report_harm_present = report_h2_ok || report_h3_ok;
    wire report_both_harm = report_h2_ok && report_h3_ok;

    wire report_f_eligible = (report_f >= FUND_MIN) ||
                             ((report_f >= weak_fund_min) && report_harm_present) ||
                             ((report_f >= very_weak_fund_min) && report_both_harm);

    // Keep the ordinary acceptance path unchanged for non-C4 notes.
    // When BOTH harmonics support the same pitch, retain the existing 75%
    // harmonic-assisted score rule.
    wire [28:0] relaxed_score_min = SCORE_MIN - (SCORE_MIN >> 2);
    wire standard_energy_ok = report_f_eligible &&
                              ((report_score >= SCORE_MIN) ||
                               (report_both_harm && (report_score >= relaxed_score_min)));

    // C4's score intentionally excludes H2, so compare it against the existing
    // 75% relaxed score threshold and require the characteristic 33/34-bin split.
    // This keeps the lower C4 score from being rejected after the H2 de-weighting.
    wire c4_direct_energy_ok = (report_bin == 9'd33) &&
                               c4_pair_balanced &&
                               (c4_f_eff >= FUND_MIN) &&
                               (report_score >= relaxed_score_min);

    // E4-only sensitivity assist. E4 occasionally disappears at larger
    // microphone distance without being misclassified. Therefore, only E4
    // receives a modest 87.5% (= 7/8) threshold, rather than the previous
    // proposed 75% relaxation. Other notes are completely unaffected.

    wire e4_energy_ok = (report_bin == 9'd42) &&
                        (report_f >= e4_fund_min) &&
                        (report_score >= e4_score_min);

    // After a confident C5->C4 octave correction, allow the C4 score down to
    // 25% of the ordinary threshold; the stricter ratio/balance checks above
    // prevent a true C5 from being pulled down by low-frequency noise.
    // and immediately rejected by the normal fundamental threshold.
    wire c4_corrected_energy_ok = use_c4_octave_fix &&
                                  c4_octave_evidence &&
                                  (c4_score >= (SCORE_MIN >> 2));

    wire report_energy_ok = best_found &&
                            (c4_corrected_energy_ok ||
                             (!use_c4_octave_fix &&
                              (standard_energy_ok || c4_direct_energy_ok || e4_energy_ok)));

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            fft_bin      <= 9'd0;
            state        <= ST_CAPTURE;
            cand_idx     <= 4'd0;
            scan_phase   <= 4'd0;
            rd_data      <= 27'd0;
            cur_f        <= 27'd0;
            cur_h2       <= 27'd0;
            cur_h3       <= 27'd0;
            best_bin     <= 9'd0;
            best_f       <= 27'd0;
            best_h2      <= 27'd0;
            best_h3      <= 27'd0;
            best_score   <= 29'd0;
            best_found   <= 1'b0;
            c4_f         <= 27'd0;
            c4_h2        <= 27'd0;
            c4_h3        <= 27'd0;
            c4_score     <= 29'd0;
            c4_bin33     <= 27'd0;
            c4_bin34     <= 27'd0;
            fund_bin     <= 9'd0;
            fund_mag     <= 27'd0;
            second_mag   <= 27'd0;
            third_mag    <= 27'd0;
            confidence   <= 2'd0;
            second_ok    <= 1'b0;
            third_ok     <= 1'b0;
            pitch_valid  <= 1'b0;
        end else begin
            case (state)
                ST_CAPTURE: begin
                    if (fft_valid) begin
                        if (fft_bin <= 9'd206)
                            spectrum[fft_bin] <= mag;

                        if (fft_last) begin
                            fft_bin      <= 9'd0;
                            cand_idx     <= 4'd0;
                            scan_phase   <= 4'd0;
                            cur_f        <= 27'd0;
                            cur_h2       <= 27'd0;
                            cur_h3       <= 27'd0;
                            best_bin     <= 9'd0;
                            best_f       <= 27'd0;
                            best_h2      <= 27'd0;
                            best_h3      <= 27'd0;
                            best_score   <= 29'd0;
                            best_found   <= 1'b0;
                            c4_f         <= 27'd0;
                            c4_h2        <= 27'd0;
                            c4_h3        <= 27'd0;
                            c4_score     <= 29'd0;
                            c4_bin33     <= 27'd0;
                            c4_bin34     <= 27'd0;
                            state        <= ST_READ;
                        end else begin
                            fft_bin <= fft_bin + 9'd1;
                        end
                    end
                end

                ST_READ: begin
                    rd_data <= spectrum[scan_addr];
                    state   <= ST_PROCESS;
                end

                ST_PROCESS: begin
                    // For the C4 octave guard, remember the two bins around
                    // the theoretical 33.49-bin fundamental separately.
                    if (cand_idx == 4'd0) begin
                        if (scan_phase == 4'd1)
                            c4_bin33 <= rd_data;
                        else if (scan_phase == 4'd2)
                            c4_bin34 <= rd_data;
                    end

                    if (scan_phase <= 4'd2) begin
                        if (rd_data > cur_f)
                            cur_f <= rd_data;
                    end else if (scan_phase <= 4'd5) begin
                        if (rd_data > cur_h2)
                            cur_h2 <= rd_data;
                    end else begin
                        if (rd_data > cur_h3)
                            cur_h3 <= rd_data;
                    end

                    if (scan_phase == 4'd10) begin
                        state <= ST_EVAL;
                    end else begin
                        scan_phase <= scan_phase + 4'd1;
                        state <= ST_READ;
                    end
                end

                ST_EVAL: begin
                    // candidate 0 is C4: retain its evidence for octave guard
                    if (cand_idx == 4'd0) begin
                        c4_f     <= cur_f;
                        c4_h2    <= cur_h2;
                        c4_h3    <= cur_h3;
                        c4_score <= cur_score;
                    end

                    if (cur_better) begin
                        best_bin   <= cand_bin;
                        best_f     <= cur_f;
                        best_h2    <= cur_h2;
                        best_h3    <= cur_h3;
                        best_score <= cur_score;
                        best_found <= 1'b1;
                    end

                    if (cand_idx == 4'd12) begin
                        state <= ST_REPORT;
                    end else begin
                        cand_idx   <= cand_idx + 4'd1;
                        scan_phase <= 4'd0;
                        cur_f      <= 27'd0;
                        cur_h2     <= 27'd0;
                        cur_h3     <= 27'd0;
                        state      <= ST_READ;
                    end
                end

                ST_REPORT: begin
                    if (!report_energy_ok) begin
                        fund_bin     <= 9'd0;
                        fund_mag     <= 27'd0;
                        second_mag   <= 27'd0;
                        third_mag    <= 27'd0;
                        confidence   <= 2'd0;
                        second_ok    <= 1'b0;
                        third_ok     <= 1'b0;
                        pitch_valid  <= 1'b0;
                    end else begin
                        fund_bin     <= report_bin;
                        fund_mag     <= report_f;
                        second_mag   <= report_h2;
                        third_mag    <= report_h3;
                        second_ok    <= report_h2_ok;
                        third_ok     <= report_h3_ok;
                        pitch_valid  <= 1'b1;

                        if (report_h2_ok && report_h3_ok)
                            confidence <= 2'd3;
                        else if (report_h2_ok || report_h3_ok)
                            confidence <= 2'd2;
                        else
                            confidence <= 2'd1;
                    end

                    done  <= 1'b1;
                    state <= ST_CAPTURE;
                end

                default: state <= ST_CAPTURE;
            endcase
        end
    end
endmodule