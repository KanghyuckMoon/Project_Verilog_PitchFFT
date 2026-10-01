`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: note_display
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


// Four-digit display.
// SINGLE mode: left two digits = detected note, right two = target note.
// CHORD  mode: left two digits = detected note1, right two = detected note2.
// Sharp notes use the decimal point on the LETTER digit:
// C.4 means C#4, F.4 means F#4, etc.
module note_display(
    input  wire       clk,
    input  wire       mode_chord,
    input  wire [3:0] heard,
    input  wire [3:0] target,
    input  wire [3:0] chord1,
    input  wire [3:0] chord2,
    output reg  [6:0] seg,        // {g,f,e,d,c,b,a}, active-low
    output reg  [3:0] an,         // active-low
    output reg        dp          // active-low
);
    function [6:0] letter;
        input [3:0] n;
        begin
            case (n)
                4'd1, 4'd2, 4'd13: letter = 7'b1000110; // C / C# / C5
                4'd3, 4'd4:        letter = 7'b0100001; // d / d#
                4'd5:              letter = 7'b0000110; // E
                4'd6, 4'd7:        letter = 7'b0001110; // F / F#
                4'd8, 4'd9:        letter = 7'b0000010; // G / G# (middle bar ON)
                4'd10, 4'd11:      letter = 7'b0001000; // A / A#
                4'd12:             letter = 7'b0000011; // b
                default:           letter = 7'b0111111; // -
            endcase
        end
    endfunction

    function [6:0] octave;
        input [3:0] n;
        begin
            case (n)
                4'd0:  octave = 7'b0111111; // -
                4'd13: octave = 7'b0010010; // 5
                default: octave = 7'b0011001; // 4
            endcase
        end
    endfunction

    function is_sharp;
        input [3:0] n;
        begin
            case (n)
                4'd2, 4'd4, 4'd7, 4'd9, 4'd11: is_sharp = 1'b1;
                default:                        is_sharp = 1'b0;
            endcase
        end
    endfunction

    wire [3:0] left_note  = mode_chord ? chord1 : heard;
    wire [3:0] right_note = mode_chord ? chord2 : target;

    reg [18:0] refresh = 19'd0;
    always @(posedge clk)
        refresh <= refresh + 19'd1;

    always @(*) begin
        dp = 1'b1;
        case (refresh[18:17])
            2'd0: begin
                an  = 4'b0111;
                seg = letter(left_note);
                dp  = is_sharp(left_note) ? 1'b0 : 1'b1;
            end
            2'd1: begin
                an  = 4'b1011;
                seg = octave(left_note);
                dp  = 1'b1;
            end
            2'd2: begin
                an  = 4'b1101;
                seg = letter(right_note);
                dp  = is_sharp(right_note) ? 1'b0 : 1'b1;
            end
            default: begin
                an  = 4'b1110;
                seg = octave(right_note);
                dp  = 1'b1;
            end
        endcase
    end
endmodule