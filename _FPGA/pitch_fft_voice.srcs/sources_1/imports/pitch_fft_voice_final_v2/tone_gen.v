`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: tone_gen
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


// Target-note square-wave generator, clk = 100 MHz.
module tone_gen(
    input  wire       clk,
    input  wire [3:0] note,
    input  wire       en,
    output reg        buz = 1'b0
);
    reg [17:0] half;

    always @(*) begin
        case (note)
            4'd1:  half = 18'd191113; // C4  261.63 Hz
            4'd2:  half = 18'd180386; // C#4 277.18 Hz
            4'd3:  half = 18'd170262; // D4  293.66 Hz
            4'd4:  half = 18'd160706; // D#4 311.13 Hz
            4'd5:  half = 18'd151686; // E4  329.63 Hz
            4'd6:  half = 18'd143173; // F4  349.23 Hz
            4'd7:  half = 18'd135137; // F#4 369.99 Hz
            4'd8:  half = 18'd127553; // G4  392.00 Hz
            4'd9:  half = 18'd120394; // G#4 415.30 Hz
            4'd10: half = 18'd113636; // A4  440.00 Hz
            4'd11: half = 18'd107258; // A#4 466.16 Hz
            4'd12: half = 18'd101238; // B4  493.88 Hz
            4'd13: half = 18'd95556;  // C5  523.25 Hz
            default: half = 18'd0;
        endcase
    end

    reg [17:0] cnt = 18'd0;

    always @(posedge clk) begin
        if (!en || half == 18'd0) begin
            cnt <= 18'd0;
            buz <= 1'b0;
        end else if (cnt >= half - 18'd1) begin
            cnt <= 18'd0;
            buz <= ~buz;
        end else begin
            cnt <= cnt + 18'd1;
        end
    end
endmodule