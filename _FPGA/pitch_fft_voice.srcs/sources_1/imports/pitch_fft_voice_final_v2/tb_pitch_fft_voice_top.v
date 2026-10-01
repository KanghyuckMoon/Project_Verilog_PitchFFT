`timescale 1ns / 1ps
// Integration testbench.
// Requires the Vivado-generated xfft_0 simulation model.
//
// It verifies the same A4 note under three spectral conditions:
//   1) pure fundamental                 -> LOW confidence
//   2) fundamental + 2nd harmonic      -> MID confidence
//   3) fundamental + 2nd + 3rd         -> HIGH confidence
// In all three cases, the pitch itself must still be detected as A4.
module tb_pitch_fft_voice_top;
    reg clk = 1'b0;
    reg btnC = 1'b1;
    reg btnU = 1'b0;
    reg [7:0] sw_tgt = 8'b0010_0000; // SW5 -> A4
    reg ja_rx = 1'b1;

    wire [15:0] led;
    wire [6:0] seg;
    wire [3:0] an;
    wire dp, ja_buz;
    wire jb_bck, jb_lrck, jb_din;

    always #5 clk = ~clk; // 100MHz

    // Faster UART only for simulation: 40 clocks/bit.
    pitch_fft_voice_top #(
        .CLKS_PER_BIT(40)
    ) dut (
        .clk(clk), .btnC(btnC), .btnU(btnU), .sw_tgt(sw_tgt),
        .ja_rx(ja_rx), .led(led), .seg(seg), .an(an), .dp(dp), .ja_buz(ja_buz),
        .jb_bck(jb_bck), .jb_lrck(jb_lrck), .jb_din(jb_din)
    );

    task uart_send_byte;
        input [7:0] b;
        integer j;
        begin
            ja_rx = 1'b0; repeat(40) @(posedge clk); // start
            for (j=0; j<8; j=j+1) begin
                ja_rx = b[j]; repeat(40) @(posedge clk);
            end
            ja_rx = 1'b1; repeat(40) @(posedge clk); // stop
        end
    endtask

    task send_frame;
        input real f0;
        input real a1;
        input real a2;
        input real a3;
        integer n;
        integer s;
        real t;
        real x;
        begin
            for (n=0; n<256; n=n+1) begin
                t = n / 4000.0;
                x = 128.0
                  + a1*$sin(2.0*3.141592653589793*f0*t)
                  + a2*$sin(2.0*3.141592653589793*2.0*f0*t)
                  + a3*$sin(2.0*3.141592653589793*3.0*f0*t);
                s = $rtoi(x);
                if (s < 0)   s = 0;
                if (s > 255) s = 255;
                uart_send_byte(s[7:0]);
            end
        end
    endtask

    task reset_dut;
        begin
            btnC = 1'b1;
            repeat(30) @(posedge clk);
            btnC = 1'b0;
            repeat(200) @(posedge clk);
        end
    endtask

    task send_four_frames;
        input real a1;
        input real a2;
        input real a3;
        begin
            send_frame(440.0, a1, a2, a3);
            send_frame(440.0, a1, a2, a3);
            send_frame(440.0, a1, a2, a3);
            send_frame(440.0, a1, a2, a3);
            repeat(100000) @(posedge clk);
        end
    endtask

    initial begin
        // --------------------------------------------------------
        // TEST 1: pure A4. Harmonics absent -> LOW, but A4 is valid.
        // --------------------------------------------------------
        reset_dut();
        send_four_frames(45.0, 0.0, 0.0);
        if (led[5] && led[8] && !led[9] && !led[10] && led[15])
            $display("[PASS] PURE A4 -> A4, LOW confidence");
        else
            $display("[FAIL] PURE A4 led=%h", led);

        // --------------------------------------------------------
        // TEST 2: A4 + 2nd harmonic -> MID.
        // --------------------------------------------------------
        reset_dut();
        send_four_frames(38.0, 18.0, 0.0);
        if (led[5] && !led[8] && led[9] && !led[10] && led[11] && led[15])
            $display("[PASS] A4 + H2 -> A4, MID confidence");
        else
            $display("[FAIL] A4 + H2 led=%h", led);

        // --------------------------------------------------------
        // TEST 3: A4 + 2nd + 3rd harmonics -> HIGH.
        // --------------------------------------------------------
        reset_dut();
        send_four_frames(34.0, 18.0, 10.0);
        if (led[5] && !led[8] && !led[9] && led[10] && led[11] && led[12] && led[15])
            $display("[PASS] VOICE-LIKE A4 -> A4, HIGH confidence");
        else
            $display("[FAIL] VOICE-LIKE A4 led=%h", led);

        $finish;
    end
endmodule
