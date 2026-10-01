`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/29/2026 03:13:14 PM
// Design Name: 
// Module Name: uart_rx
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


module uart_rx #(
    parameter CLKS_PER_BIT = 400          // 100MHz / 250000bps
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data  = 8'd0,
    output reg        valid = 1'b0
);
    // External UART is asynchronous to clk -> 2-FF synchronizer.
    reg rx_s1 = 1'b1, rx_s2 = 1'b1;
    always @(posedge clk) begin
        rx_s1 <= rx;
        rx_s2 <= rx_s1;
    end

    localparam IDLE  = 2'd0,
               START = 2'd1,
               DATA  = 2'd2,
               STOP  = 2'd3;

    reg [1:0]  state   = IDLE;
    reg [13:0] cnt     = 14'd0;
    reg [2:0]  bit_idx = 3'd0;
    reg [7:0]  shreg   = 8'd0;

    always @(posedge clk) begin
        valid <= 1'b0;

        if (rst) begin
            state   <= IDLE;
            cnt     <= 14'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'd0;
            data    <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    cnt     <= 14'd0;
                    bit_idx <= 3'd0;
                    if (rx_s2 == 1'b0)
                        state <= START;
                end

                START: begin
                    if (cnt == CLKS_PER_BIT/2) begin
                        cnt <= 14'd0;
                        state <= (rx_s2 == 1'b0) ? DATA : IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                DATA: begin
                    if (cnt == CLKS_PER_BIT-1) begin
                        cnt   <= 14'd0;
                        shreg <= {rx_s2, shreg[7:1]};
                        if (bit_idx == 3'd7)
                            state <= STOP;
                        else
                            bit_idx <= bit_idx + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                STOP: begin
                    if (cnt == CLKS_PER_BIT-1) begin
                        cnt   <= 14'd0;
                        state <= IDLE;
                        if (rx_s2 == 1'b1) begin
                            data  <= shreg;
                            valid <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule