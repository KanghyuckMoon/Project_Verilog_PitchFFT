`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 11:34:42 AM
// Design Name: 
// Module Name: audio_record_playback
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
module audio_record_playback
(
    input  wire       clk,
    input  wire       rst,

    input  wire [7:0] sample_in,
    input  wire       sample_valid,

    output wire       bck,
    output wire       lrck,
    output wire       din
);

    localparam RECORD = 1'b0;
    localparam PLAY   = 1'b1;

    reg state;

    // 1초 @ 4kHz
    (* ram_style = "block" *)
    reg [7:0] audio_mem [0:3999];

    reg [11:0] write_addr;
    reg [11:0] read_addr;

    reg [3:0] repeat_count;
    reg [7:0] playback_sample;

    wire request_next_sample;


    // ------------------------------------------------------------
    // I2S transmitter
    // ------------------------------------------------------------
    i2s_pcm5102_tx u_i2s
    (
        .clk(clk),
        .rst(rst),

        .sample_8bit(playback_sample),
        .enable(state == PLAY),

        .request_next_sample(request_next_sample),

        .bck(bck),
        .lrck(lrck),
        .din(din)
    );


    // ------------------------------------------------------------
    // RECORD / PLAY FSM
    // ------------------------------------------------------------
    always @(posedge clk)
    begin
        if (rst)
        begin
            state <= RECORD;

            write_addr <= 12'd0;
            read_addr <= 12'd0;

            repeat_count <= 4'd0;
            playback_sample <= 8'd128;
        end
        else
        begin
            case (state)

                // =================================================
                // RECORD
                // =================================================
                RECORD:
                begin
                    repeat_count <= 4'd0;
                    read_addr <= 12'd0;

                    if (sample_valid)
                    begin
                        audio_mem[write_addr] <= sample_in;

                        if (write_addr == 12'd3999)
                        begin
                            write_addr <= 12'd0;

                            // 첫 재생 샘플 준비
                            playback_sample <= audio_mem[0];

                            read_addr <= 12'd0;
                            repeat_count <= 4'd0;

                            state <= PLAY;
                        end
                        else
                        begin
                            write_addr <= write_addr + 1'b1;
                        end
                    end
                end


                // =================================================
                // PLAY
                // =================================================
                PLAY:
                begin
                    if (request_next_sample)
                    begin
                        // 하나의 4kHz 샘플을
                        // 48kHz에서 12번 반복
                        if (repeat_count == 4'd11)
                        begin
                            repeat_count <= 4'd0;

                            if (read_addr == 12'd3999)
                            begin
                                read_addr <= 12'd0;
                                write_addr <= 12'd0;

                                playback_sample <= 8'd128;

                                state <= RECORD;
                            end
                            else
                            begin
                                read_addr <= read_addr + 1'b1;

                                playback_sample <=
                                    audio_mem[read_addr + 1'b1];
                            end
                        end
                        else
                        begin
                            repeat_count <= repeat_count + 1'b1;
                        end
                    end
                end


                default:
                begin
                    state <= RECORD;

                    write_addr <= 12'd0;
                    read_addr <= 12'd0;

                    repeat_count <= 4'd0;
                    playback_sample <= 8'd128;
                end

            endcase
        end
    end

endmodule
