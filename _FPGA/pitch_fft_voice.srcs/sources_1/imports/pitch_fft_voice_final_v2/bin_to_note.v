`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: bin_to_note
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
// 512-point FFT bin -> chromatic note class (C4..C5)
// Fs = 4000 Hz, N = 512, df = 7.8125 Hz/bin
//
// Boundaries are placed at equal-tempered semitone midpoints.
// Valid fundamental bins for this one-octave game are 33..68.
// ============================================================
module bin_to_note(
    input  wire [8:0] bin,
    input  wire       valid_pitch,
    output reg  [3:0] note
);
    always @(*) begin
        if (!valid_pitch || bin < 9'd33 || bin > 9'd68)
            note = 4'd0;
        else if (bin <= 9'd34) note = 4'd1;   // C4
        else if (bin <= 9'd36) note = 4'd2;   // C#4
        else if (bin <= 9'd38) note = 4'd3;   // D4
        else if (bin <= 9'd40) note = 4'd4;   // D#4
        else if (bin <= 9'd43) note = 4'd5;   // E4
        else if (bin <= 9'd46) note = 4'd6;   // F4
        else if (bin <= 9'd48) note = 4'd7;   // F#4
        else if (bin <= 9'd51) note = 4'd8;   // G4
        else if (bin <= 9'd54) note = 4'd9;   // G#4
        else if (bin <= 9'd57) note = 4'd10;  // A4
        else if (bin <= 9'd61) note = 4'd11;  // A#4
        else if (bin <= 9'd65) note = 4'd12;  // B4
        else                   note = 4'd13;  // C5
    end
endmodule