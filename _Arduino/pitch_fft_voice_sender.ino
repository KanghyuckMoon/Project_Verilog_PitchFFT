// ============================================================
// Final version - Arduino sound sampler for Basys3 FFT pitch game
// Sampling: 4 kHz, UART: 250000 bps
// MODE = 0 : real microphone
// MODE = 1 : pure sine test
// MODE = 2 : harmonic-rich fake voice test (recommended first test)
// ============================================================

const int MIC_PIN = A0;
const unsigned long SAMPLE_US = 250;   // 250 us -> 4000 samples/s

const byte MODE = 0;                   // 0=MIC, 1=PURE, 2=HARMONIC TEST
const float FAKE_HZ = 440.0;           // A4 test tone

byte tablePure[256];
byte tableVoice[256];
unsigned int phase = 0;                // 0~65535 phase accumulator
unsigned int step;
unsigned long next_t;

static byte clipByte(float x) {
  if (x < 0.0)   return 0;
  if (x > 255.0) return 255;
  return (byte)(x + 0.5);
}

void setup() {
  Serial.begin(250000);                // D1(TX) -> divider -> Basys3 JA1

  // Test tables are generated only once at startup.
  // MODE=2 intentionally includes 2nd/3rd harmonics like a simple voice-like signal.
  for (int i = 0; i < 256; i++) {
    float a = 2.0 * PI * i / 256.0;

    float pure = 128.0 + 50.0 * sin(a);
    tablePure[i] = clipByte(pure);

    float voiceLike = 128.0
                    + 34.0 * sin(a)       // fundamental f0
                    + 18.0 * sin(2.0*a)   // 2nd harmonic 2f0
                    + 10.0 * sin(3.0*a);  // 3rd harmonic 3f0
    tableVoice[i] = clipByte(voiceLike);
  }

  step = (unsigned int)(FAKE_HZ * 65536.0 / 4000.0);
  next_t = micros();
}

void loop() {
  // Keep the sampling interval close to 250 us.
  while ((long)(micros() - next_t) < 0) { }
  next_t += SAMPLE_US;

  byte s;

  if (MODE == 1) {
    s = tablePure[phase >> 8];
    phase += step;
  }
  else if (MODE == 2) {
    s = tableVoice[phase >> 8];
    phase += step;
  }
  else {
    // Arduino ADC: 0~1023 -> one byte 0~255.
    // Centering and Hann window are done on the FPGA side.
    s = analogRead(MIC_PIN) >> 2;
  }

  Serial.write(s);                       // raw 1-byte sample
}
