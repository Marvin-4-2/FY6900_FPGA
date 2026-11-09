# Register map

The STM32 front-panel firmware controls the FPGA through 64 registers of 32 bits
(addresses 0x00–0x3F, of which about 50 are used). The transport is described in
[spi-protocol.md](spi-protocol.md); the firmware-side sequences are described in
[firmware-notes.md](firmware-notes.md).

All values below were reconstructed from the stock firmware (versions 1.4.2 and 1.8.0),
confirmed with the SPI sniffer, and checked on the device with this FPGA design.
"FW" means the stock STM32 firmware; X is the reference frequency (10 MHz by default,
see [calibration.md](calibration.md)).

## Overview

| Reg | Dir | Name | Used by this design |
|---|---|---|---|
| 0x00 | W | dummy write at power-on | ignored |
| 0x01 | W | counter control | yes |
| 0x02 | R | counter result | yes |
| 0x03 | R | counter status | yes |
| 0x04 | W | waveform mode CH1/CH2 | yes |
| 0x05 | W | output enable, uplink, counter input, range relays | yes |
| 0x06:0x07 | W | CH1 frequency (64 bit) | yes |
| 0x08:0x09 | W | CH2 frequency (64 bit) | yes |
| 0x0A / 0x0B | W | CH1 / CH2 start phase | yes |
| 0x0C | R | flash byte read result | yes |
| 0x0D | W | flash byte read strobe | yes |
| 0x0E | W | authentication: challenge index | ignored |
| 0x0F | W | waveform transfer target | yes |
| 0x11, 0x13, 0x14, 0x16 | W | flash erase / write | not implemented yet (future extension) |
| 0x12 | W | waveform transfer strobe | yes |
| 0x15 | R | flash busy | yes |
| 0x17 | W | flash address | yes |
| 0x18 | W | MANU key / manual trigger | yes |
| 0x19 | W | burst count and keying source | yes |
| 0x1A, 0x1C | W | authentication: response | ignored |
| 0x1B | R | authentication: challenge data | returns 0 |
| 0x1D | W | Adj-Pulse width (CH1) | yes |
| 0x1E:0x20 | W | FM deviation / FSK hop frequency (64 bit) | yes |
| 0x1F | R | FPGA ID | returns 0x10 |
| 0x21 | W | modulation mode | yes |
| 0x22:0x23 | W | reference: 25·X in µHz (64 bit) | yes (frequency calibration) |
| 0x24 | W | counter gate 1 s = 5·X | yes |
| 0x25 | W | counter gate 10 s = 50·X | yes |
| 0x26:0x27 | W | counter gate 100 s = 500·X (64 bit) | yes |
| 0x28 | W | core reset | ignored |
| 0x29 / 0x2A | W | CH1 / CH2 offset | yes |
| 0x2B / 0x2C | W | CH1 / CH2 amplitude | yes |
| 0x2D | W | VCO-IN sample | yes |
| 0x2E | W | AM depth | yes |
| 0x2F | W | apply phases (sync channels) | yes |
| 0x30 / 0x31 | W | CH1 / CH2 duty cycle | yes |
| 0x32 / 0x33 | W | CH1 / CH2 trapezoid slopes | yes |
| 0x34 / 0x35 | W | CH1 / CH2 trapezoid edge widths | yes |
| 0x36 | W | PM deviation ("BIAS") | yes |
| 0x3A | R | FPGA ID / version | returns 0x00FB6910 |

64-bit values are split into two registers: the lower address holds the upper 32 bits
(e.g. 0x06 = high word, 0x07 = low word; for the modulation frequency 0x1E = high,
0x20 = low).

## Signal generation

### 0x04 – waveform mode

`reg04 = mode_CH1 | (mode_CH2 << 3)`

| Mode | Waveform | Notes |
|---|---|---|
| 0 | table waveform (sine, ramp, arbitrary, …) | wave RAM loaded from flash |
| 1 | square / rectangle | duty from 0x30/0x31; edge interpolation |
| 2 | trapezoid | edges from 0x32–0x35, duty from 0x30/0x31 |
| 3 | CMOS / PWM | unipolar (mid scale … full scale), FW writes twice the amplitude |
| 4 | Adj-Pulse (CH1 only) | unipolar, fixed pulse width from 0x1D |
| 7 | DC, or channel switched off | DAC at mid scale, level set by the offset |

The FW maps its waveform list as follows (1.8.0): CH1 index 1/2 → mode 1, 3 → 2, 4 → 3,
5 → 4 (Adj-Pulse, additionally `W 1D`), 6 → 7 (DC), all others → 0 with a waveform transfer.
CH2 has no Adj-Pulse: 1/2 → 1, 3 → 2, 4 → 3, 5 → 7. A channel that is switched off gets mode 7.

### 0x05 – output enable, uplink, counter input, range relays

| Bit | Function |
|---|---|
| 8 | CH1 output on (1) / off (0) – informational, the FW also sets mode 7 and centres the offset |
| 7 | CH2 output on / off – as bit 8 |
| 6:5 | uplink: `10` off, `00` master, `11` slave (see [fpga-design.md](fpga-design.md#uplink)) |
| 4 | counter input ("COUPLING"): 0 = AC = Counter BNC (pin 135), 1 = DC = Trig IN (pin 144) |
| 3 | CH1 range relay "large" (gain, from approx. 6 Vpp) |
| 2 | CH1 range relay "small" (attenuator, up to approx. 350 mV) |
| 1 | CH2 range relay "large" |
| 0 | CH2 range relay "small" |

Normal value with both outputs on and uplink off: `0x1C0`. The FW selects the range from
amplitude and offset (bits 3:2 = `01` if Amp/20 + |Offset| ≤ 350 and Amp ≤ 5000 and
|Offset| ≤ 250; `10` if Amp/20 + |Offset| > 3500 or Amp > 50000 or |Offset| > 2500;
otherwise `00`; values in mV). On every range change the FW sets the amplitude to 0,
writes reg 0x05 repeatedly and ramps the amplitude up again – that is the relay click.

### 0x06:0x07 / 0x08:0x09 – frequency

64-bit frequency in units of **0.1 Hz** (e.g. 1 kHz = 10000). The FPGA converts it into a
48-bit phase increment at 125 MHz: `inc = F · K >> 16` with `K = 0x3_6F9B_FB3B` for
X = 10 MHz (see 0x22:0x23).

### 0x0A / 0x0B, 0x2F – start phase

20-bit start phase, 2^20 = 360°. The FW writes `(360000 − phase[m°]) × 2.91271`, so 0° is
written as 0xFFFFF. A write to 0x2F (any value) loads both phase accumulators with their
start phases, which also aligns the two channels.

### 0x30 / 0x31 – duty cycle

2^17 = 100 % (FW: `duty[0.001 %] × 1.31072`). Square/CMOS output is high while the phase is
below the duty value.

### 0x32–0x35 – trapezoid

* 0x34/0x35: `rise << 14 | fall`, edge widths in 1/16384 of a period
* 0x32/0x33: `(16383 / rise) << 14 | (16383 / fall)`, the matching slopes

The trapezoid rises for `rise`, stays high until the duty point, falls for `fall` and stays
low for the rest of the period.

### 0x1D – Adj-Pulse width (CH1)

Pulse width in **4 ns units** (FW: `width_ns / 4`). The width stays constant when the
frequency changes; a width longer than the period gives a constant high level.

### 0x29 / 0x2A – offset, 0x2B / 0x2C – amplitude

12-bit values for the two MCP4822 DACs of each channel. Offset: centre 0x7FF (0 V),
MCP4822 gain 2×. Amplitude: MCP4822 gain 1×, the output sets the reference (REFI/O) and
therefore the full-scale current of the waveform DAC. On CH1 the offset is VOUTA and the
amplitude VOUTB, on CH2 the outputs are swapped.

## Modulation (CH1)

### 0x21 – modulation mode

| Bit | Meaning |
|---|---|
| 0 | PSK (180° phase shift while keyed) |
| 1 | FSK (hop frequency from 0x1E:0x20 while keyed) |
| 2 | ASK (carrier on while keyed, otherwise off) |
| 3 | AM (depth from 0x2E) |
| 4 | external source: with AM/FM/PM = Ext.(VCO-IN) (sample in 0x2D); set at power-on (0x10) |
| 5 | FM (deviation from 0x1E:0x20) |
| 6 | PM (deviation from 0x36) |
| 7 | strobe after writing the 64-bit values (FM/FSK) – not needed by this design |

**BURST** has no mode bit: the FW writes `0x21 = 0x10` and selects a source in 0x19.
Leaving the modulation menu writes `0x21 = 0x10` (or 0x00) and 0x19 without source bits.

### 0x19 – burst count and keying source

* bits 19:0: burst count N (1 … 1 000 000; 0 = no output, see MANU below)
* bits 23:20: source + 1 for FSK/ASK/PSK/BURST: 1 = CH2, 2 = Ext.(AC) = Counter input,
  3 = MANU, 4 = Ext.(DC) = Trig IN; 0 = none (AM/FM/PM and outside the modulation menu)

With CH2 as source the keying condition is "CH2 in the upper half of its range" and the
burst trigger is the rising mid-scale crossing of CH2. External sources are keyed by their
logic level and trigger on the rising edge.

### 0x18 – MANU key

Level of the OK key when the source is MANU: 0 = pressed, 1 = released (power-on value 1).
FSK/ASK/PSK: keyed while the key is pressed. BURST: the FW writes 0 and immediately 1, the
rising edge triggers the burst. Firmware 1.8.0 first writes burst count 0 when MANU is
selected and pulses 0x18 – the burst is armed but silent until OK writes the real count.

### 0x1E:0x20 – FM deviation / FSK hop frequency

64-bit value in 0.1 Hz units (same scale as the carrier frequency). FM: peak deviation for
full-scale modulation. FSK: frequency while keyed.

### 0x2E – AM depth

`depth[0.1 %] × 2047 / 2000`, 2047 = 100 %. The peak level of the AM signal equals the
set amplitude: `out = carrier · (1 + d·m) / (1 + d)`.

### 0x36 – PM deviation

`deviation[0.01°] × 3.640861`, i.e. 360° = 131071 ≈ 2^17. Called "BIAS" in the menu.
Peak phase deviation for full-scale modulation.

### 0x2D – VCO-IN sample

With an external AM/FM/PM source the FW samples the VCO-IN socket with the STM32 ADC and
streams the value (×1.1, limited to 4095) to the FPGA in short 16-bit SPI frames without an
address (see [spi-protocol.md](spi-protocol.md#vco-in-frames)). This design stores them in
0x2D. Centre 0x800 = no modulation; the input range of the socket is 0–5 V (2.5 V = 0).

## Waveform transfer and flash access

The STM32 has no direct access to the SPI flash; it uses the FPGA.

| Reg | Function |
|---|---|
| 0x17 | flash address (24 bit) |
| 0x0F | target of a waveform transfer: 1 = CH1, 2 = CH2 (0 = boot/aux, ignored) |
| 0x12 | rising edge of bit 0: transfer 16384 bytes (8192 × 14-bit samples) from 0x17 into the wave RAM |
| 0x0D | rising edge of bit 0: read one byte at 0x17 (FW pulses 1, 1, 0, 0) |
| 0x0C | R: byte read, bit order `{f3, f5, f0, f1, f6, f4, f2, f7}` of the flash byte f |
| 0x15 | R: busy (≠ 0 while a transfer runs) |
| 0x11, 0x13, 0x14, 0x16 | sector erase, byte write, write data, write sequence – not implemented yet, see [fpga-design.md](fpga-design.md#future-extension-flash-writes) |

Waveforms are stored as 8192 samples × 14 bit little endian, every byte bit-permuted;
the FPGA unscrambles a flash byte f as `{f4, f2, f7, f0, f1, f6, f3, f5}`.

## Frequency counter

### 0x01 – control

| Bit | Meaning |
|---|---|
| 0 | 0 → 1: restart the pulse width measurement |
| 1 | 0 → 1: start the gate time (FREQU) or set the zero point (COUNT) |
| 2 | 0 = FREQU, 1 = COUNT |
| 4:3 | value in 0x02: 00 = frequency / count, 01 = −width, 11 = +width |
| 6:5 | gate: 00 = 1 s, 01 = 10 s, 10 = 100 s |

### 0x02 / 0x03 – result and status

* 0x02: edges within the gate time, or the event count, or a pulse width in 4 ns units
* 0x03: bit 0 = pulse widths ready, bit 1 = gate running, bit 2 = input permanently high,
  bit 3 = input permanently low

The FW computes CYCLE = +width + −width and DUTY = +width / CYCLE.

### 0x22:0x23, 0x24–0x27 – reference

* 0x24 = 5·X, 0x25 = 50·X, 0x26:0x27 = 500·X: gate times in ticks of 5·X (50 MHz)
* 0x22:0x23 = 25 000 000·X = 25·X in µHz: the DDS clock of the original FPGA (250 MHz)

This design runs its DDS at 12.5·X and derives its frequency constant from 0x22:0x23, so
the FW's frequency calibration corrects the generator and the counter together.

## Identification and other registers

| Reg | Value / behaviour |
|---|---|
| 0x1F (R) | 0x10 – checked by the FW at power-on (`R 1F & 0x1F == 0x10`) |
| 0x3A (R) | 0x00FB6910 – FW 1.8.0 polls bits 23:8 = 0xFB69 at power-on (up to 200 × 20 ms), bits 7:0 = version |
| 0x00 (W) | written with 0 at power-on before the ID check (SPI alignment), ignored |
| 0x28 (W) | core reset, written 0/1 at power-on, ignored |
| 0x0E, 0x1A, 0x1C (W), 0x1B (R) | authentication handshake, see [firmware-notes.md](firmware-notes.md#authentication) – ignored, 0x1B returns 0 |
