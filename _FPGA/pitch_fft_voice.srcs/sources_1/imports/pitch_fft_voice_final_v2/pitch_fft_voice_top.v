`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: pitch_fft_voice_top
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

module pitch_fft_voice_top #(
    parameter integer CLKS_PER_BIT      = 400,
    parameter [26:0] FUND_MIN           = 27'd240,
    parameter [26:0] HARM_MIN           = 27'd200,
    parameter [28:0] SCORE_MIN          = 29'd1400,
    parameter [26:0] CHORD_FUND_MIN     = 27'd120,
    parameter [28:0] CHORD_SCORE_MIN    = 29'd700
)(
    input  wire        clk,        // Basys3 100 MHz
    input  wire        btnC,       // reset
    input  wire        btnU,       // single mode: play selected target while pressed
    input  wire        mode_chord, // SW15: 0=single, 1=two-note chord
    input  wire [3:0]  sw_tgt,     // single: note 0..13, chord: SW2..0 preset 0..7
    input  wire        ja_rx,      // JA1 from Arduino TX through 5V->3.3V divider
    output reg  [15:0] led,
    output wire [6:0]  seg,
    output wire [3:0]  an,
    output wire        dp,
    output wire        ja_buz
);
    // ------------------------------------------------------------
    // 1) UART: one unsigned 8-bit audio sample at a time
    // 100 MHz / 250000 bps = 400 clocks/bit
    // ------------------------------------------------------------
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(btnC), .rx(ja_rx),
        .data(rx_data), .valid(rx_valid)
    );

    // ------------------------------------------------------------
    // 2) One-entry sample buffer + 512-sample frame index
    // ------------------------------------------------------------
    reg [7:0] pending_raw = 8'd128;
    reg       pending     = 1'b0;
    reg [8:0] sample_idx  = 9'd0;

    wire signed [15:0] centered_sample = $signed({8'd0, pending_raw}) - 16'sd128;
    wire signed [15:0] windowed_sample;

    hann_window u_hann (
        .index(sample_idx),
        .sample_in(centered_sample),
        .sample_out(windowed_sample)
    );

    wire in_ready;
    wire cfg_ready;
    reg  cfg_done = 1'b0;

    wire sample_handshake = pending && cfg_done && in_ready;
    wire in_last = (sample_idx == 9'd511);

    always @(posedge clk) begin
        if (btnC) begin
            pending_raw <= 8'd128;
            pending     <= 1'b0;
            sample_idx  <= 9'd0;
        end else begin
            if (sample_handshake) begin
                pending <= 1'b0;
                if (sample_idx == 9'd511)
                    sample_idx <= 9'd0;
                else
                    sample_idx <= sample_idx + 9'd1;
            end

            if (rx_valid && !pending) begin
                pending_raw <= rx_data;
                pending     <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------
    // 3) FFT configuration: forward transform
    // ------------------------------------------------------------
    always @(posedge clk) begin
        if (btnC)
            cfg_done <= 1'b0;
        else if (!cfg_done && cfg_ready)
            cfg_done <= 1'b1;
    end

    // ------------------------------------------------------------
    // 4) 512-point FFT IP
    // ------------------------------------------------------------
    wire [63:0] out_data;
    wire        out_valid;
    wire        out_last;

    xfft_0 u_fft (
        .aclk                 (clk),
        .aresetn              (~btnC),
        .s_axis_config_tdata  (8'h01),
        .s_axis_config_tvalid (!cfg_done),
        .s_axis_config_tready (cfg_ready),
        .s_axis_data_tdata    ({16'd0, windowed_sample}),
        .s_axis_data_tvalid   (pending && cfg_done),
        .s_axis_data_tready   (in_ready),
        .s_axis_data_tlast    (in_last),
        .m_axis_data_tdata    (out_data),
        .m_axis_data_tvalid   (out_valid),
        .m_axis_data_tready   (1'b1),
        .m_axis_data_tlast    (out_last)
    );

    // ------------------------------------------------------------
    // 5) SINGLE-NOTE detector (existing harmonic-aware detector)
    // ------------------------------------------------------------
    wire [8:0]  fund_bin;
    wire [26:0] fund_mag;
    wire [26:0] second_mag;
    wire [26:0] third_mag;
    wire [1:0]  confidence;
    wire        second_ok;
    wire        third_ok;
    wire        pitch_valid;
    wire        detector_done;

    harmonic_pitch_detector #(
        .FUND_LO(33),
        .FUND_HI(68),
        .FUND_MIN(FUND_MIN),
        .HARM_MIN(HARM_MIN),
        .SCORE_MIN(SCORE_MIN)
    ) u_detector (
        .clk(clk), .rst(btnC),
        .fft_valid(out_valid), .fft_last(out_last), .fft_data(out_data),
        .fund_bin(fund_bin), .fund_mag(fund_mag),
        .second_mag(second_mag), .third_mag(third_mag),
        .confidence(confidence), .second_ok(second_ok), .third_ok(third_ok),
        .pitch_valid(pitch_valid), .done(detector_done)
    );

    wire [3:0] frame_note;
    bin_to_note u_b2n (
        .bin(fund_bin), .valid_pitch(pitch_valid), .note(frame_note)
    );

    // ------------------------------------------------------------
    // 6) CHORD detector: two simultaneous notes from the SAME FFT
    // ------------------------------------------------------------
    wire [3:0] chord_frame1;
    wire [3:0] chord_frame2;
    wire       chord_frame_valid;
    wire       chord_done;

    chord_pitch_detector #(
        .FUND_MIN(CHORD_FUND_MIN),
        .SCORE_MIN(CHORD_SCORE_MIN)
    ) u_chord_detector (
        .clk(clk), .rst(btnC),
        .fft_valid(out_valid), .fft_last(out_last), .fft_data(out_data),
        .note1(chord_frame1), .note2(chord_frame2),
        .chord_valid(chord_frame_valid), .done(chord_done)
    );

    // Clear stale FND data when the mode switch changes.
    reg mode_d = 1'b0;
    wire mode_changed = (mode_d != mode_chord);
    always @(posedge clk) begin
        if (btnC)
            mode_d <= mode_chord;
        else
            mode_d <= mode_chord;
    end

    // ------------------------------------------------------------
    // 7) Stable SINGLE display + silence release
    // Two matching frames confirm a note; two missing frames clear it.
    // ------------------------------------------------------------
    reg [3:0] prev_note = 4'd0;
    reg [1:0] same_count = 2'd0;
    reg [1:0] silence_count = 2'd0;
    reg [3:0] heard = 4'd0;
    reg       heard_second_ok = 1'b0;
    reg       heard_third_ok  = 1'b0;

    always @(posedge clk) begin
        if (btnC || mode_changed) begin
            prev_note       <= 4'd0;
            same_count      <= 2'd0;
            silence_count   <= 2'd0;
            heard           <= 4'd0;
            heard_second_ok <= 1'b0;
            heard_third_ok  <= 1'b0;
        end else if (detector_done) begin
            if (frame_note == 4'd0) begin
                if (silence_count == 2'd0)
                    silence_count <= 2'd1;
                else begin
                    silence_count   <= 2'd2;
                    prev_note       <= 4'd0;
                    same_count      <= 2'd0;
                    heard           <= 4'd0;
                    heard_second_ok <= 1'b0;
                    heard_third_ok  <= 1'b0;
                end
            end else begin
                silence_count <= 2'd0;
                if (frame_note == prev_note) begin
                    if (same_count < 2'd2)
                        same_count <= same_count + 2'd1;
                    if (same_count >= 2'd1) begin
                        heard           <= frame_note;
                        heard_second_ok <= second_ok;
                        heard_third_ok  <= third_ok;
                    end
                end else begin
                    prev_note  <= frame_note;
                    same_count <= 2'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // 8) Stable CHORD display + silence release
    // Two CONSECUTIVE identical valid chord frames are required before
    // changing the FND. This suppresses the piano attack transient where
    // C4+E4 can briefly look like C5+E4.
    // chord detector already sorts note1 < note2.
    // ------------------------------------------------------------
    reg [3:0] chord_prev1 = 4'd0;
    reg [3:0] chord_prev2 = 4'd0;
    reg [1:0] chord_same_count = 2'd0;
    reg [1:0] chord_silence_count = 2'd0;
    reg [3:0] chord_heard1 = 4'd0;
    reg [3:0] chord_heard2 = 4'd0;
    reg       chord_heard_valid = 1'b0;

    always @(posedge clk) begin
        if (btnC || mode_changed) begin
            chord_prev1         <= 4'd0;
            chord_prev2         <= 4'd0;
            chord_same_count    <= 2'd0;
            chord_silence_count <= 2'd0;
            chord_heard1        <= 4'd0;
            chord_heard2        <= 4'd0;
            chord_heard_valid   <= 1'b0;
        end else if (chord_done) begin
            if (!chord_frame_valid) begin
                // A missing/invalid frame breaks the 2-frame confirmation
                // sequence, but the previous confirmed chord is kept on the
                // FND until two invalid frames occur.
                chord_prev1      <= 4'd0;
                chord_prev2      <= 4'd0;
                chord_same_count <= 2'd0;

                if (chord_silence_count == 2'd0) begin
                    chord_silence_count <= 2'd1;
                end else begin
                    chord_silence_count <= 2'd2;
                    chord_heard1        <= 4'd0;
                    chord_heard2        <= 4'd0;
                    chord_heard_valid   <= 1'b0;
                end
            end else begin
                chord_silence_count <= 2'd0;

                if ((chord_frame1 == chord_prev1) &&
                    (chord_frame2 == chord_prev2)) begin
                    // Second consecutive identical valid frame: confirm it.
                    if (chord_same_count < 2'd2)
                        chord_same_count <= chord_same_count + 2'd1;

                    if (chord_same_count >= 2'd1) begin
                        chord_heard1      <= chord_frame1;
                        chord_heard2      <= chord_frame2;
                        chord_heard_valid <= 1'b1;
                    end
                end else begin
                    // First frame of a new chord: remember it but do not
                    // display it yet. This rejects the short piano attack
                    // error such as C5+E4 before C4+E4 settles.
                    chord_prev1      <= chord_frame1;
                    chord_prev2      <= chord_frame2;
                    chord_same_count <= 2'd1;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // 9) Targets
    // SINGLE (SW15=0): SW3..0 = 1:C4 ... 13:C5
    // CHORD  (SW15=1): SW2..0 selects one of eight two-note targets.
    // ------------------------------------------------------------
    reg [3:0] single_target;
    always @(*) begin
        if ((sw_tgt >= 4'd1) && (sw_tgt <= 4'd13))
            single_target = sw_tgt;
        else
            single_target = 4'd0;
    end

    reg [3:0] chord_target1;
    reg [3:0] chord_target2;
    // All game presets intentionally avoid octave pairs such as C4+C5,
    // because the upper fundamental coincides with the lower note's H2.
    always @(*) begin
        case (sw_tgt[2:0])
            3'b000: begin chord_target1 = 4'd1;  chord_target2 = 4'd5;  end // C4 + E4
            3'b001: begin chord_target1 = 4'd1;  chord_target2 = 4'd8;  end // C4 + G4
            3'b010: begin chord_target1 = 4'd3;  chord_target2 = 4'd7;  end // D4 + F#4
            3'b011: begin chord_target1 = 4'd3;  chord_target2 = 4'd10; end // D4 + A4
            3'b100: begin chord_target1 = 4'd5;  chord_target2 = 4'd9;  end // E4 + G#4
            3'b101: begin chord_target1 = 4'd6;  chord_target2 = 4'd10; end // F4 + A4
            3'b110: begin chord_target1 = 4'd8;  chord_target2 = 4'd12; end // G4 + B4
            default: begin chord_target1 = 4'd10; chord_target2 = 4'd13; end // A4 + C5
        endcase
    end

    wire single_match = (single_target != 4'd0) && (heard == single_target);
    wire chord_match = chord_heard_valid &&
                       (((chord_heard1 == chord_target1) && (chord_heard2 == chord_target2)) ||
                        ((chord_heard1 == chord_target2) && (chord_heard2 == chord_target1)));

    // ------------------------------------------------------------
    // 10) LEDs
    // SINGLE mode:
    //   LD0..12 detected note, LD13 any H2/H3, LD14 both, LD15 MATCH.
    // CHORD mode:
    //   LD0..12 TARGET chord notes, LD13 chord-mode marker,
    //   LD14 two detected notes valid, LD15 both notes MATCH.
    // ------------------------------------------------------------
    always @(*) begin
        led = 16'd0;

        if (!mode_chord) begin
            if ((heard >= 4'd1) && (heard <= 4'd13))
                led[heard - 4'd1] = 1'b1;
            led[13] = heard_second_ok || heard_third_ok;
            led[14] = heard_second_ok && heard_third_ok;
            led[15] = single_match;
        end else begin
            if ((chord_target1 >= 4'd1) && (chord_target1 <= 4'd13))
                led[chord_target1 - 4'd1] = 1'b1;
            if ((chord_target2 >= 4'd1) && (chord_target2 <= 4'd13))
                led[chord_target2 - 4'd1] = 1'b1;
            led[13] = 1'b1;              // chord mode
            led[14] = chord_heard_valid; // two notes detected
            led[15] = chord_match;       // both notes match target
        end
    end

    // ------------------------------------------------------------
    // 11) FND
    // SINGLE: [detected note][target note]
    // CHORD : [detected note1][detected note2]
    // ------------------------------------------------------------
    note_display u_disp (
        .clk(clk),
        .mode_chord(mode_chord),
        .heard(heard),
        .target(single_target),
        .chord1(chord_heard1),
        .chord2(chord_heard2),
        .seg(seg), .an(an), .dp(dp)
    );

    // Existing target-tone output is kept only in single mode.
    // (A single square-wave output is not a clean two-note chord source.)
    tone_gen u_tone (
        .clk(clk), .note(single_target),
        .en(btnU && !mode_chord), .buz(ja_buz)
    );
endmodule