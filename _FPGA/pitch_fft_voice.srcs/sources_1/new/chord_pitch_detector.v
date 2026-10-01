`timescale 1ns / 1ps
// ============================================================
// Timing-friendly TWO-NOTE detector for chord mode
// 512-point FFT, Fs = 4000 Hz, C4..C5 chromatic candidates.
//
// Chord-mode improvements:
//   1) Each note uses its own NON-OVERLAPPING 2-bin fundamental region.
//      This prevents adjacent semitones from sharing the same fundamental bin.
//      Examples:
//          C4  -> bins 33,34
//          C#4 -> bins 35,36
//          D4  -> bins 37,38
//          ...
//          B4  -> bins 63,64
//          C5  -> bins 66,67
//   2) Adjacent semitone pairs are allowed (C4+C#4, B4+C5, etc.).
//   3) C4 keeps its piano-octave protection:
//          F_eff = max(bin33,bin34) + 0.5*min(bin33,bin34)
//      and C4 H2 (~C5) is not added to the C4 ranking score.
//   4) In chord mode only, C4 may use a modest 87.5% threshold when
//      BOTH bins 33/34 form a believable C4 pair. This helps when a
//      second simultaneous note partially masks the C4 fundamental.
//   5) C4 has a rescue path similar to the single-note detector: even if
//      it misses the direct threshold, a believable 33/34 split plus H2
//      relationship can keep C4 alive in chord mode.
//   6) C5 suppression no longer depends on C4 first passing direct-valid.
//   7) If rescued C4 is the weaker second note, the pair-ratio floor is
//      relaxed from 25% to 18.75% only for that case.
//   8) Chord ranking is FUNDAMENTAL-dominant. Harmonics still validate a note,
//      but their ranking weight is reduced so piano overtones do not make the
//      selected pair jump from frame to frame.
//   9) A held-pair hysteresis keeps the previous chord through small score
//      fluctuations, while allowing immediate C5->C4 octave correction.
//  10) Low-energy piano tails are rejected instead of being reclassified,
//      and the tail reference is reset when the accepted pair changes.
//
// Exact octave pair C4+C5 remains intentionally unsupported because
// C5 fundamental and C4 H2 occupy the same frequency region.
// ============================================================
module chord_pitch_detector #(
    parameter [26:0] FUND_MIN  = 27'd120,
    parameter [28:0] SCORE_MIN = 29'd700
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        fft_valid,
    input  wire        fft_last,
    input  wire [63:0] fft_data,

    output reg  [3:0]  note1       = 4'd0,
    output reg  [3:0]  note2       = 4'd0,
    output reg         chord_valid = 1'b0,
    output reg         done        = 1'b0
);

    // ------------------------------------------------------------
    // FFT magnitude
    // 512-point / 16-bit fixed-point / unscaled -> 26-bit components
    // ------------------------------------------------------------
    wire signed [25:0] re = fft_data[25:0];
    wire signed [25:0] im = fft_data[57:32];
    wire [25:0] abs_re = re[25] ? (~re + 26'd1) : re;
    wire [25:0] abs_im = im[25] ? (~im + 26'd1) : im;
    wire [26:0] mag = {1'b0, abs_re} + {1'b0, abs_im};

    // Only bins through 3*C5 (+ margin) are needed.
    reg [26:0] spectrum [0:255];
    reg [8:0] fft_bin = 9'd0;

    // ------------------------------------------------------------
    // Frame-level energy tracking for piano-tail rejection
    // ------------------------------------------------------------
    reg [26:0] capture_peak = 27'd0;
    reg [26:0] frame_peak   = 27'd0;

    // ------------------------------------------------------------
    // Rounded note centers used only for H2/H3 lookup.
    // ------------------------------------------------------------
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

    // ------------------------------------------------------------
    // Non-overlapping 2-bin fundamental regions.
    // Adjacent semitones never share a fundamental bin.
    // ------------------------------------------------------------
    function [8:0] note_fund_bin_a;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  note_fund_bin_a = 9'd33; // C4
                4'd1:  note_fund_bin_a = 9'd35; // C#4
                4'd2:  note_fund_bin_a = 9'd37; // D4
                4'd3:  note_fund_bin_a = 9'd39; // D#4
                4'd4:  note_fund_bin_a = 9'd42; // E4
                4'd5:  note_fund_bin_a = 9'd44; // F4
                4'd6:  note_fund_bin_a = 9'd47; // F#4
                4'd7:  note_fund_bin_a = 9'd50; // G4
                4'd8:  note_fund_bin_a = 9'd53; // G#4
                4'd9:  note_fund_bin_a = 9'd56; // A4
                4'd10: note_fund_bin_a = 9'd59; // A#4
                4'd11: note_fund_bin_a = 9'd63; // B4
                default: note_fund_bin_a = 9'd66; // C5
            endcase
        end
    endfunction

    function [8:0] note_fund_bin_b;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  note_fund_bin_b = 9'd34; // C4
                4'd1:  note_fund_bin_b = 9'd36; // C#4
                4'd2:  note_fund_bin_b = 9'd38; // D4
                4'd3:  note_fund_bin_b = 9'd40; // D#4
                4'd4:  note_fund_bin_b = 9'd43; // E4
                4'd5:  note_fund_bin_b = 9'd45; // F4
                4'd6:  note_fund_bin_b = 9'd48; // F#4
                4'd7:  note_fund_bin_b = 9'd51; // G4
                4'd8:  note_fund_bin_b = 9'd54; // G#4
                4'd9:  note_fund_bin_b = 9'd57; // A4
                4'd10: note_fund_bin_b = 9'd60; // A#4
                4'd11: note_fund_bin_b = 9'd64; // B4
                default: note_fund_bin_b = 9'd67; // C5
            endcase
        end
    endfunction

    localparam [3:0] ST_CAPTURE = 4'd0,
                     ST_READ    = 4'd1,
                     ST_PROCESS = 4'd2,
                     ST_EVAL    = 4'd3,
                     ST_SEL1    = 4'd4,
                     ST_SEL2    = 4'd5,
                     ST_REPORT  = 4'd6;

    reg [3:0] state = ST_CAPTURE;
    reg [3:0] cand_idx = 4'd0;

    wire [8:0] cand_bin = note_center_bin(cand_idx);
    wire [8:0] fund_bin_a = note_fund_bin_a(cand_idx);
    wire [8:0] fund_bin_b = note_fund_bin_b(cand_idx);
    wire [8:0] two_k = cand_bin << 1;
    wire [8:0] three_k = cand_bin + (cand_bin << 1);

    // Scan phases:
    //   0..1 : two NON-OVERLAPPING fundamental bins
    //   2..4 : H2 = 2k-1 .. 2k+1
    //   5..9 : H3 = 3k-2 .. 3k+2
    reg [3:0] scan_phase = 4'd0;
    reg [8:0] scan_addr;

    always @(*) begin
        case (scan_phase)
            4'd0: scan_addr = fund_bin_a;
            4'd1: scan_addr = fund_bin_b;
            4'd2: scan_addr = two_k - 9'd1;
            4'd3: scan_addr = two_k;
            4'd4: scan_addr = two_k + 9'd1;
            4'd5: scan_addr = three_k - 9'd2;
            4'd6: scan_addr = three_k - 9'd1;
            4'd7: scan_addr = three_k;
            4'd8: scan_addr = three_k + 9'd1;
            default: scan_addr = three_k + 9'd2; // phase 9
        endcase
    end

    reg [26:0] rd_data = 27'd0;
    reg [26:0] cur_f  = 27'd0;
    reg [26:0] cur_h2 = 27'd0;
    reg [26:0] cur_h3 = 27'd0;

    // ------------------------------------------------------------
    // C4-specific scoring
    // ------------------------------------------------------------
    reg [26:0] c4_bin33 = 27'd0;
    reg [26:0] c4_bin34 = 27'd0;

    wire [27:0] c4_pair_sum = {1'b0, c4_bin33} + {1'b0, c4_bin34};
    wire [26:0] c4_pair_max = (c4_bin33 > c4_bin34) ? c4_bin33 : c4_bin34;
    wire [26:0] c4_pair_min = (c4_bin33 < c4_bin34) ? c4_bin33 : c4_bin34;

    // C4 at 33.49 naturally spreads over bins 33 and 34.
    // Recover part of the split energy without simply doubling the scale.
    wire [27:0] c4_f_eff = {1'b0, c4_pair_max}
                           + ({1'b0, c4_pair_min} >> 1);

    // A real C4 should normally contribute to both bins 33 and 34.
    wire c4_pair_balanced =
        (c4_pair_max != 27'd0) &&
        (c4_pair_min >= (c4_pair_max >> 2)); // weaker >= 25% of stronger

    // Validation score keeps the original harmonic-aware weighting.
    // This decides whether a note has enough spectral evidence to be a candidate.
    //     VALID = 2*F + H2 + H3/2
    wire [28:0] normal_score = {1'b0, cur_f, 1'b0}
                               + {2'b00, cur_h2}
                               + ({2'b00, cur_h3} >> 1);

    // Chord RANKING is deliberately more fundamental-dominant:
    //     RANK = 2*F + H2/2 + H3/4
    // Piano harmonics change strongly from attack -> sustain.  Using their full
    // magnitude for ranking made the top-two candidates jump between frames.
    wire [28:0] normal_rank_score = {1'b0, cur_f, 1'b0}
                                    + ({2'b00, cur_h2} >> 1)
                                    + ({2'b00, cur_h3} >> 2);

    // C4 validation/ranking.  H2 is deliberately excluded because C4 H2 ~= C5.
    // C4 already uses the recovered 33/34 split fundamental.
    wire [28:0] c4_special_score = {c4_f_eff, 1'b0}
                                   + ({2'b00, cur_h3} >> 1);
    wire [28:0] c4_rank_score = {c4_f_eff, 1'b0}
                                + ({2'b00, cur_h3} >> 2);

    wire c4_candidate = (cand_idx == 4'd0);
    wire [28:0] cur_rank_score =
        c4_candidate ? c4_rank_score : normal_rank_score;

    // In two-note mode C4 can be partially masked by the other tone.
    // Allow only a modest 87.5% relaxation, and only when the characteristic
    // 33/34 split is actually present. Other notes keep the original threshold.
    wire [27:0] c4_fund_min = {1'b0, FUND_MIN} - ({1'b0, FUND_MIN} >> 3);
    wire [28:0] c4_score_min = SCORE_MIN - (SCORE_MIN >> 3);

    wire c4_direct_valid = c4_pair_balanced &&
                           (c4_f_eff >= c4_fund_min) &&
                           (c4_special_score >= c4_score_min);

    // C4 rescue path: mirror the single-note detector's philosophy.
    // Even when C4 misses the direct threshold, keep it alive if the
    // characteristic 33/34 split and harmonic relation are still present.
    wire [27:0] c4_rescue_fund_min = ({1'b0, FUND_MIN} >> 2); // 25%
    wire [28:0] c4_rescue_score_min = (SCORE_MIN >> 2);       // 25%
    wire c4_rescue_evidence = c4_pair_balanced &&
                              (c4_f_eff >= c4_rescue_fund_min) &&
                              (c4_special_score >= c4_rescue_score_min) &&
                              (cur_h2 >= FUND_MIN);

    wire normal_valid = (cur_f >= FUND_MIN) &&
                        (normal_score >= SCORE_MIN);

    wire cur_valid = c4_candidate ?
                     (c4_direct_valid || c4_rescue_evidence) :
                     normal_valid;

    // Per-note results.
    reg [28:0] score_mem [0:12];
    reg [26:0] fund_mem  [0:12];
    reg        valid_mem [0:12];

    // Remember C4 evidence across the rest of the candidate scan.
    reg c4_direct_seen = 1'b0;
    reg c4_rescue_seen = 1'b0;
    reg [26:0] c4_h3_seen_mag = 27'd0;

    // ------------------------------------------------------------
    // C5 -> C4 harmonic suppression for chord mode
    // ------------------------------------------------------------
    // Normal C4/C5 ratio check: C4 pair >= 18.75% of C5 fundamental.
    wire [27:0] c4_vs_c5_floor_strict =
        ({1'b0, cur_f} >> 3) + ({1'b0, cur_f} >> 4);
    wire c4_visible_under_c5_strict =
        (c4_pair_sum >= c4_vs_c5_floor_strict);

    // Attack-aware ratio check: 12.5%.  This is used only with stronger C4
    // evidence (direct C4, or rescued C4 that also has a visible H3).
    // It helps the first piano attack frame, where C4 H2 at C5 can temporarily
    // be much larger than the C4 fundamental.
    wire [27:0] c4_vs_c5_floor_attack = ({1'b0, cur_f} >> 3);
    wire c4_visible_under_c5_attack =
        (c4_pair_sum >= c4_vs_c5_floor_attack);

    wire c4_h3_support = (c4_h3_seen_mag >= FUND_MIN);

    // Exact C4+C5 remains intentionally unsupported.  A C5 candidate is
    // suppressed as C4's H2 when:
    //   - direct C4 evidence exists and the relaxed attack ratio is met, OR
    //   - rescued C4 has H3 support and the attack ratio is met, OR
    //   - rescued C4 meets the original stricter 18.75% ratio.
    wire suppress_c5_as_c4_h2 =
        (cand_idx == 4'd12) &&
        c4_pair_balanced &&
        ((c4_direct_seen && c4_visible_under_c5_attack) ||
         (c4_rescue_seen && c4_h3_support && c4_visible_under_c5_attack) ||
         (c4_rescue_seen && c4_visible_under_c5_strict));

    wire stored_valid = cur_valid && !suppress_c5_as_c4_h2;
    wire [28:0] stored_score = stored_valid ? cur_rank_score : 29'd0;

    integer i;
    reg [3:0] sel_idx = 4'd0;
    reg [3:0] best1_idx = 4'd0;
    reg [3:0] best2_idx = 4'd0;
    reg [28:0] best1_score = 29'd0;
    reg [28:0] best2_score = 29'd0;
    reg best1_found = 1'b0;
    reg best2_found = 1'b0;

    // ------------------------------------------------------------
    // Second-note selection
    // ------------------------------------------------------------
    // IMPORTANT: adjacent semitones are now ALLOWED.
    // Non-overlapping fundamental bins handle the separation instead of
    // simply banning neighboring note indices.
    wire same_note_duplicate = (sel_idx == best1_idx);

    // Exact octave C4+C5 remains unsupported.
    wire octave_duplicate = ((best1_idx == 4'd0) && (sel_idx == 4'd12)) ||
                            ((best1_idx == 4'd12) && (sel_idx == 4'd0));

    wire second_candidate_allowed = valid_mem[sel_idx] &&
                                    !same_note_duplicate &&
                                    !octave_duplicate;

    // A real second tone should carry a meaningful fraction of the first.
    // Keep the existing 25% criterion; nearby semitones are no longer rejected
    // structurally, so this still filters weak leakage/noise candidates.
    wire second_ratio_ok_normal = best2_score >= (best1_score >> 2);

    // If C4 survived only through the rescue path and became the weaker
    // second note, relax the pair-ratio check from 25% to 18.75%.
    wire [28:0] c4_rescue_ratio_floor =
        (best1_score >> 3) + (best1_score >> 4);
    wire second_ratio_ok_c4_rescue =
        (best2_idx == 4'd0) && c4_rescue_seen &&
        (best2_score >= c4_rescue_ratio_floor);

    wire second_ratio_ok = second_ratio_ok_normal ||
                           second_ratio_ok_c4_rescue;

    // ------------------------------------------------------------
    // Low-energy piano-tail guard
    // ------------------------------------------------------------
    wire base_pair_valid = best1_found && best2_found && second_ratio_ok;

    // Sorted current pair, as zero-based indices and user-facing note codes.
    wire [3:0] report_idx1 = (best1_idx < best2_idx) ? best1_idx : best2_idx;
    wire [3:0] report_idx2 = (best1_idx < best2_idx) ? best2_idx : best1_idx;
    wire [3:0] report_note1 = report_idx1 + 4'd1;
    wire [3:0] report_note2 = report_idx2 + 4'd1;

    // ------------------------------------------------------------
    // Pair hysteresis
    // ------------------------------------------------------------
    // Keep the previous accepted chord while both of its notes are still valid
    // in the current frame and a challenger is only slightly stronger.
    // This removes frame-to-frame "wobble" caused by changing piano harmonics.
    reg [3:0] held_idx1 = 4'd0;
    reg [3:0] held_idx2 = 4'd0;
    reg       held_valid = 1'b0;

    wire held_pair_present = held_valid &&
                             valid_mem[held_idx1] &&
                             valid_mem[held_idx2];

    wire same_as_held = held_valid &&
                        (report_idx1 == held_idx1) &&
                        (report_idx2 == held_idx2);

    wire [29:0] new_pair_score =
        {1'b0, best1_score} + {1'b0, best2_score};
    wire [29:0] held_pair_score =
        {1'b0, score_mem[held_idx1]} + {1'b0, score_mem[held_idx2]};

    // Challenger must be at least 12.5% stronger to replace a still-valid pair.
    wire [29:0] held_switch_floor =
        held_pair_score + (held_pair_score >> 3);
    wire challenger_clearly_better =
        (new_pair_score >= held_switch_floor);

    // Special case: if the held pair contains C5 and the new pair replaces that
    // C5 with C4 while keeping the same other note, accept the correction
    // immediately.  Do not let hysteresis preserve an octave error.
    wire c5_to_c4_correction =
        held_valid &&
        (held_idx2 == 4'd12) &&
        (report_idx1 == 4'd0) &&
        (held_idx1 == report_idx2);

    // Tail guard is defined below.  These pair-choice wires are completed after
    // tail_guard_ok is available.

    // Learn level after the same accepted pair has appeared twice.
    reg [3:0] level_pair1 = 4'd0;
    reg [3:0] level_pair2 = 4'd0;
    reg       level_pair_seen = 1'b0;
    reg [26:0] event_peak = 27'd0;
    reg [26:0] prev_frame_peak = 27'd0;

    // Frames below 25% of the established level are treated as decay tail.
    wire tail_level_ok = (event_peak == 27'd0) ||
                         (frame_peak >= (event_peak >> 2));

    // New attack re-arm: >= 1.5x previous frame and at least 12.5% of
    // the previous event reference.
    wire [27:0] attack_rise_floor = {1'b0, prev_frame_peak} +
                                    ({1'b0, prev_frame_peak} >> 1);
    wire attack_rearm = (event_peak != 27'd0) &&
                        ({1'b0, frame_peak} >= attack_rise_floor) &&
                        (frame_peak >= (event_peak >> 3));

    wire tail_guard_ok = tail_level_ok || attack_rearm;

    // Raw new pair is usable only when both-note and tail checks pass.
    wire raw_pair_valid = base_pair_valid && tail_guard_ok;

    wire choose_new_pair =
        raw_pair_valid &&
        (!held_valid ||
         same_as_held ||
         c5_to_c4_correction ||
         !held_pair_present ||
         challenger_clearly_better);

    // If the raw winner changes only slightly but the old pair is still
    // spectrally present, keep the old pair for this frame.
    wire choose_held_pair =
        held_valid &&
        held_pair_present &&
        tail_guard_ok &&
        (!raw_pair_valid || !choose_new_pair);

    wire output_pair_valid = choose_new_pair || choose_held_pair;
    wire [3:0] output_idx1 = choose_new_pair ? report_idx1 : held_idx1;
    wire [3:0] output_idx2 = choose_new_pair ? report_idx2 : held_idx2;
    wire [3:0] output_note1 = output_idx1 + 4'd1;
    wire [3:0] output_note2 = output_idx2 + 4'd1;

    wire same_level_pair = level_pair_seen &&
                           (output_note1 == level_pair1) &&
                           (output_note2 == level_pair2);

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            fft_bin          <= 9'd0;
            capture_peak     <= 27'd0;
            frame_peak       <= 27'd0;
            state            <= ST_CAPTURE;
            cand_idx         <= 4'd0;
            scan_phase       <= 4'd0;
            rd_data          <= 27'd0;
            cur_f            <= 27'd0;
            cur_h2           <= 27'd0;
            cur_h3           <= 27'd0;
            c4_bin33         <= 27'd0;
            c4_bin34         <= 27'd0;
            c4_direct_seen   <= 1'b0;
            c4_rescue_seen   <= 1'b0;
            c4_h3_seen_mag   <= 27'd0;
            held_idx1        <= 4'd0;
            held_idx2        <= 4'd0;
            held_valid       <= 1'b0;
            sel_idx          <= 4'd0;
            best1_idx        <= 4'd0;
            best2_idx        <= 4'd0;
            best1_score      <= 29'd0;
            best2_score      <= 29'd0;
            best1_found      <= 1'b0;
            best2_found      <= 1'b0;
            note1            <= 4'd0;
            note2            <= 4'd0;
            chord_valid      <= 1'b0;
            level_pair1      <= 4'd0;
            level_pair2      <= 4'd0;
            level_pair_seen  <= 1'b0;
            event_peak       <= 27'd0;
            prev_frame_peak  <= 27'd0;

            for (i = 0; i < 13; i = i + 1) begin
                score_mem[i] <= 29'd0;
                fund_mem[i]  <= 27'd0;
                valid_mem[i] <= 1'b0;
            end
        end else begin
            case (state)
                ST_CAPTURE: begin
                    if (fft_valid) begin
                        if (fft_bin <= 9'd206)
                            spectrum[fft_bin] <= mag;

                        // Ignore DC/very-low bins for frame-level energy.
                        if ((fft_bin >= 9'd20) && (fft_bin <= 9'd206) &&
                            (mag > capture_peak))
                            capture_peak <= mag;

                        if (fft_last) begin
                            fft_bin      <= 9'd0;
                            frame_peak   <= capture_peak;
                            capture_peak <= 27'd0;
                            cand_idx     <= 4'd0;
                            scan_phase   <= 4'd0;
                            cur_f        <= 27'd0;
                            cur_h2       <= 27'd0;
                            cur_h3       <= 27'd0;
                            c4_bin33       <= 27'd0;
                            c4_bin34       <= 27'd0;
                            c4_direct_seen <= 1'b0;
                            c4_rescue_seen <= 1'b0;
                            c4_h3_seen_mag <= 27'd0;
                            state          <= ST_READ;
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
                    // C4's two dedicated fundamental bins.
                    if (cand_idx == 4'd0) begin
                        if (scan_phase == 4'd0)
                            c4_bin33 <= rd_data;
                        else if (scan_phase == 4'd1)
                            c4_bin34 <= rd_data;
                    end

                    if (scan_phase <= 4'd1) begin
                        if (rd_data > cur_f)
                            cur_f <= rd_data;
                    end else if (scan_phase <= 4'd4) begin
                        if (rd_data > cur_h2)
                            cur_h2 <= rd_data;
                    end else begin
                        if (rd_data > cur_h3)
                            cur_h3 <= rd_data;
                    end

                    if (scan_phase == 4'd9) begin
                        state <= ST_EVAL;
                    end else begin
                        scan_phase <= scan_phase + 4'd1;
                        state <= ST_READ;
                    end
                end

                ST_EVAL: begin
                    // Preserve C4 evidence so the later C5 candidate can be
                    // reinterpreted as C4's H2 even if C4 only passed rescue.
                    if (cand_idx == 4'd0) begin
                        c4_direct_seen <= c4_direct_valid;
                        c4_rescue_seen <= c4_rescue_evidence;
                        c4_h3_seen_mag <= cur_h3;
                    end

                    // Candidate 12 (C5) may be suppressed when the same frame
                    // already contains characteristic C4 evidence.
                    score_mem[cand_idx] <= stored_score;
                    fund_mem[cand_idx]  <= cur_f;
                    valid_mem[cand_idx] <= stored_valid;

                    if (cand_idx == 4'd12) begin
                        sel_idx      <= 4'd0;
                        best1_idx    <= 4'd0;
                        best1_score  <= 29'd0;
                        best1_found  <= 1'b0;
                        state        <= ST_SEL1;
                    end else begin
                        cand_idx   <= cand_idx + 4'd1;
                        scan_phase <= 4'd0;
                        cur_f      <= 27'd0;
                        cur_h2     <= 27'd0;
                        cur_h3     <= 27'd0;
                        state      <= ST_READ;
                    end
                end

                ST_SEL1: begin
                    if (valid_mem[sel_idx] &&
                        (!best1_found || (score_mem[sel_idx] > best1_score))) begin
                        best1_idx   <= sel_idx;
                        best1_score <= score_mem[sel_idx];
                        best1_found <= 1'b1;
                    end

                    if (sel_idx == 4'd12) begin
                        sel_idx      <= 4'd0;
                        best2_idx    <= 4'd0;
                        best2_score  <= 29'd0;
                        best2_found  <= 1'b0;
                        state        <= ST_SEL2;
                    end else begin
                        sel_idx <= sel_idx + 4'd1;
                    end
                end

                ST_SEL2: begin
                    if (second_candidate_allowed &&
                        (!best2_found || (score_mem[sel_idx] > best2_score))) begin
                        best2_idx   <= sel_idx;
                        best2_score <= score_mem[sel_idx];
                        best2_found <= 1'b1;
                    end

                    if (sel_idx == 4'd12)
                        state <= ST_REPORT;
                    else
                        sel_idx <= sel_idx + 4'd1;
                end

                ST_REPORT: begin
                    // Remember this frame level for attack re-arming.
                    prev_frame_peak <= frame_peak;

                    // Update the held pair only when a genuinely new pair wins
                    // the hysteresis decision.  A one-frame/small score wobble
                    // therefore does not change the detector output.
                    if (choose_new_pair) begin
                        held_idx1  <= report_idx1;
                        held_idx2  <= report_idx2;
                        held_valid <= 1'b1;
                    end else if (!output_pair_valid && !tail_guard_ok) begin
                        // A real low-energy tail releases the held chord.
                        held_valid <= 1'b0;
                    end

                    // Learn the tail reference from the ACCEPTED output pair,
                    // not from a raw one-frame challenger.
                    if (output_pair_valid) begin
                        if (attack_rearm) begin
                            event_peak      <= frame_peak;
                            level_pair1     <= output_note1;
                            level_pair2     <= output_note2;
                            level_pair_seen <= 1'b1;
                        end else if (!level_pair_seen || !same_level_pair) begin
                            // Pair changed: discard the old chord's level.
                            // The next matching frame will establish a fresh
                            // sustain reference instead of inheriting a stale
                            // threshold from the previous chord.
                            level_pair1     <= output_note1;
                            level_pair2     <= output_note2;
                            level_pair_seen <= 1'b1;
                            event_peak      <= 27'd0;
                        end else if (event_peak == 27'd0) begin
                            event_peak <= frame_peak;
                        end else if (tail_level_ok && (frame_peak > event_peak)) begin
                            event_peak <= frame_peak;
                        end
                    end else if (!tail_guard_ok) begin
                        // Fully released tail: reset reference for the next hit.
                        level_pair_seen <= 1'b0;
                        event_peak      <= 27'd0;
                    end

                    if (output_pair_valid) begin
                        note1       <= output_note1;
                        note2       <= output_note2;
                        chord_valid <= 1'b1;
                    end else begin
                        note1       <= 4'd0;
                        note2       <= 4'd0;
                        chord_valid <= 1'b0;
                    end

                    done  <= 1'b1;
                    state <= ST_CAPTURE;
                end

                default: state <= ST_CAPTURE;
            endcase
        end
    end
endmodule