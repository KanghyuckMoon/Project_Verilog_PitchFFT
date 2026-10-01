`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: hann_window
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


// 512-point Hann window, Q1.15 coefficients.
// sample_out = sample_in * hann[index]
module hann_window(
    input  wire [8:0]         index,
    input  wire signed [15:0] sample_in,
    output wire signed [15:0] sample_out
);
    reg [15:0] rom [0:511];

    initial begin
        $readmemh("hann512_q15.mem", rom);
    end

    wire signed [15:0] coeff = $signed(rom[index]);
    wire signed [31:0] prod  = sample_in * coeff;

    assign sample_out = prod >>> 15;
endmodule