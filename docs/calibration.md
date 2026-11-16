# Calibration

## Frequency (reference)

The frequency accuracy is set by the 10 MHz TCXO (typically a few ppm). The firmware has a
hidden calibration menu that changes the reference value X:

1. With the generator switched off, hold **Power** and the **CH1** key on the front panel,
   switch the rear power switch on, wait about 2 s and release both keys.
2. **SYSTEM** → **MORE** (lower right) → **OSCI**.
3. Measure CH1 (10 kHz) with a reference you trust and turn the knob until it reads exactly
   10.00000 kHz. Press the knob (OK), switch off and on again.

The firmware writes the new X into the reference registers (0x22–0x27); this FPGA design
derives both its DDS frequency and the counter gate times from them, so the generator and
the counter stay consistent. A loop-back test (CH1 into the counter input) therefore always
shows the set frequency and cannot detect a calibration error – you need an external
reference that is more accurate than the TCXO.

A cheap and good reference is a GPS module with a 1 PPS output (e.g. u-blox NEO-6M/M8N):
feed the PPS signal into the counter input or Trig IN and read **CYCLE**. The reading shows
the TCXO error directly (1 000 002 000 ns = TCXO 2 ppm fast); set
X = 10 000 000 × reading / 10^9. Calibrating against a typical oscilloscope timebase
(±25–50 ppm) usually makes the result worse.

## Analog (trimmers)

Each channel has three trimmers. Their function was determined on CH1 of the test unit
(FPGA board V2.1) by turning each one by 1/8 turn; CH2 has the same arrangement and was
adjusted with the same procedure.

| CH1 | CH2 | Acts on | 1/8 turn clockwise (CH1) |
|---|---|---|---|
| W26 | W16 | gain of one DAC output half – the **high** level of a square wave | +8 % |
| W5 | W3 | gain of the other DAC half – the **low** level – together with the offset and the zero; the W26/W16 half changes less | about −37 %, very sensitive |
| W2 | W1 | zero (shifts the whole output) | +16 mV |

The DAC-1412 has two complementary current outputs, and the output stage amplifies their
difference. One half passes W26 (W16); W5 (W3) acts like the feedback resistor of the
amplifier input that receives the other half together with the offset voltage from the
MCP4822. If the two halves have different gains, the centre of the waveform moves with the
amplitude. For a set amplitude A at offset 0, with the zero z and the gains g₁ (W26 half)
and g₂ (W5 half):

* high level = z + g₁ · A/2
* low level = z − g₂ · A/2
* mean value (what a DMM on V DC shows for a sine) = z + (g₁ − g₂) · A/4

So each half has a reading of its own, and the zero follows from the mean at two
amplitudes. The DC waveform outputs the DAC centre, so its reading at offset 0 also contains
the balance error until the two halves are equal – don't use it to set the zero.

The FPGA does not apply any analog correction: amplitude and offset come from the MCP4822
codes written by the firmware.

**Check the firmware first.** The firmware scales the offset with a coefficient that it
normally takes from its configuration in the SPI flash. Firmware 1.8.0 on a V1.9 / V2.1 board
whose flash still has the original layout falls back to defaults made for other hardware:
**every offset comes out about 37 % too high**, and the trimmers cannot correct that. Use
firmware 1.4.2 on these boards – see
[firmware-notes.md](firmware-notes.md#offset-and-amplitude-scaling). The amplitude is not
affected.

### Before turning anything

* Photograph or mark the current trimmer positions.
* Let the unit warm up for about 15 minutes.
* Measure into high impedance with a DMM on V DC, not into 50 Ω. Read levels with the DMM;
  the cursors of a typical oscilloscope are not accurate enough.
* W5 and W3 are very sensitive: move them by a few degrees at a time.

### Procedure (per channel)

1. **Find the zero.** Sine 1 kHz, offset 0, DMM on V DC. Read **a** at 1 Vpp and **b** at
   4 Vpp. The zero is **z = (4a − b) / 3**.
2. **Set the two halves.** Square 0.01 Hz, 4 Vpp, offset 0 – each level lasts 50 s, enough to
   turn a trimmer while watching the DMM (frequencies below 0.1 Hz need v0.20 or later; with
   older versions use 0.1 Hz):
   * low phase: **W5** (CH2: **W3**) until the DMM shows **z − 2.000 V**,
   * high phase: **W26** (CH2: **W16**) until it shows **z + 2.000 V**,
   * repeat both once, because W5 (W3) also moves the other half a little.
3. **Set the zero.** Sine 1 kHz, 4 Vpp, offset 0: **W2** (CH2: **W1**) until the DMM shows
   **0.000 V**. With equal halves the mean no longer depends on the amplitude, so this is the
   zero for every amplitude.
4. **Check.** Sine 1 Vpp and 4 Vpp: both 0.000 V. Square 4 Vpp: −2.000 / +2.000 V. Then the
   offset (DC ±1 V, and ±3 V for the large range) and a square with 10 Vpp (large range).

4 Vpp is the largest round amplitude of the middle range that is not affected by the
deviation at 5 Vpp (see below).

### What the trimmers cannot correct

* **Offset gain:** W5 (W3) changes the offset and its DAC half in a fixed ratio. On the test
  unit (CH1) the offset gain is 0.990 × the gain of that half, so with the amplitude exact the
  offset is about **1 % low** (10 mV per volt). The ratio comes from the circuit and the
  firmware's offset coefficient. The error can be split instead (amplitude about +0.5 %,
  offset about −0.5 %).
* **The 1.8.0 offset coefficients** (+37 %, see above).
* **5 Vpp:** in the middle range a setting of 5 Vpp comes out about **4.5 % larger** than
  1–4 Vpp. This was measured at two different trimmer settings (originally 1–4 Vpp within
  0.2 % and 5.22 Vpp for 5 Vpp; later +4.1 % and +8.9 %). The firmware's amplitude code is
  strictly proportional to the amplitude
  ([firmware-notes.md](firmware-notes.md#offset-and-amplitude-scaling)), so the cause is in
  the analog path. Where the deviation begins between 4 and 5 Vpp has not been measured yet.

### Results on the test unit

Before the adjustment – CH1, firmware 1.4.2, trimmers moved during earlier experiments,
Fluke 177 into high impedance:

| Quantity | Measured |
|---|---|
| zero (extrapolated from the sine means) | −49 mV |
| centre of the waveform | moves by +12.6 mV per Vpp – the two halves differed by 4.8 % |
| offset gain, middle range (DC ±1 V) / large range (DC ±3 V) | 1.012 / 1.0125 |
| amplitude 1–4 Vpp / 10 Vpp (large range) | +4.1 % / +3.6 % |
| amplitude 5 Vpp | +8.9 % |
| centre of the large range (DC ±3 V) | −186 mV |

After the adjustment (16 November 2026): both channels set to the targets of steps 2 and 3;
the 4 Vpp sine reads 1.414 Vrms on the DMM's AC range. A complete measurement series after
the adjustment – in particular the large range – is still to be done. Reports with
measurement series from other units are welcome.
