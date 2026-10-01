`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 11:35:56 AM
// Design Name: 
// Module Name: i2s_pcm5102_tx
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

module i2s_pcm5102_tx
(
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] sample_8bit,
    input  wire       enable,

    output reg        request_next_sample,

    output reg        bck,
    output reg        lrck,
    output reg        din
);

    // ------------------------------------------------------------
    // 48 kHz
    //
    // 32bit Left
    // 32bit Right
    //
    // BCK = 48000 × 64
    //     = 3.072 MHz
    //
    // BCK edge frequency = 6.144 MHz
    //
    // 100MHz에서 phase accumulator 사용
    // ------------------------------------------------------------

    localparam [31:0] PHASE_INC = 32'd263882791;

    reg [32:0] phase_acc = 33'd0;

    reg [5:0] bit_count = 6'd0;

    reg [31:0] left_word  = 32'd0;
    reg [31:0] right_word = 32'd0;

    reg signed [15:0] sample16;

    reg [32:0] phase_next;


    // ------------------------------------------------------------
    // 8-bit unsigned
    //
    // 0    -> -32768 근처
    // 128  -> 0
    // 255  -> +32512 근처
    //
    // (sample - 128) << 8
    // ------------------------------------------------------------

    always @(*)
    begin
        sample16 =
            ($signed({1'b0, sample_8bit}) - 9'sd128) <<< 8;
    end


    always @(posedge clk)
    begin
        if (rst)
        begin
            phase_acc <= 33'd0;

            bck <= 1'b0;
            lrck <= 1'b0;
            din <= 1'b0;

            bit_count <= 6'd0;

            left_word <= 32'd0;
            right_word <= 32'd0;

            request_next_sample <= 1'b0;
        end
        else
        begin
            request_next_sample <= 1'b0;

            phase_next =
                {1'b0, phase_acc[31:0]}
                +
                {1'b0, PHASE_INC};

            phase_acc <= phase_next;


            // ----------------------------------------------------
            // Accumulator overflow
            // = BCK half period
            // ----------------------------------------------------

            if (phase_next[32])
            begin
                phase_acc[32] <= 1'b0;

                bck <= ~bck;


                // ------------------------------------------------
                // falling edge에서 DIN 변경
                // PCM5102A는 rising edge에서 읽음
                // ------------------------------------------------

                if (bck == 1'b1)
                begin

                    if (!enable)
                    begin
                        din <= 1'b0;
                        lrck <= 1'b0;
                        bit_count <= 6'd0;
                    end
                    else
                    begin

                        // ----------------------------------------
                        // 새로운 Stereo frame
                        // ----------------------------------------

                        if (bit_count == 6'd0)
                        begin
                            left_word <= {
                                sample16,
                                16'd0
                            };

                            right_word <= {
                                sample16,
                                16'd0
                            };
                        end


                        // ----------------------------------------
                        // Left channel
                        // ----------------------------------------

                        if (bit_count < 6'd32)
                        begin
                            lrck <= 1'b0;

                            if (bit_count < 6'd16)
                            begin
                                din <= left_word[31 - bit_count];
                            end
                            else
                            begin
                                din <= 1'b0;
                            end
                        end

                        // ----------------------------------------
                        // Right channel
                        // ----------------------------------------

                        else
                        begin
                            lrck <= 1'b1;

                            if (bit_count < 6'd48)
                            begin
                                din <= right_word[63 - bit_count];
                            end
                            else
                            begin
                                din <= 1'b0;
                            end
                        end


                        // ----------------------------------------
                        // Frame end
                        // ----------------------------------------

                        if (bit_count == 6'd63)
                        begin
                            bit_count <= 6'd0;

                            request_next_sample <= 1'b1;
                        end
                        else
                        begin
                            bit_count <= bit_count + 1'b1;
                        end

                    end
                end
            end
        end
    end

endmodule