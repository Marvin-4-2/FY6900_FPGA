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

Each channel has three trimmers (silkscreen names on FPGA board V2.1):

| Function | CH1 | CH2 |
|---|---|---|
| Offset | W2 | W1 |
| Symmetry | W26 | W16 |
| Amplitude | W5 | W3 |

The FPGA does not apply any analog correction: amplitude and offset come from the MCP4822
codes written by the firmware.

**Check the firmware first.** The firmware scales the offset with a coefficient that it
normally takes from its configuration in the SPI flash. Firmware 1.8.0 on a V1.9 / V2.1 board
whose flash still has the original layout falls back to defaults made for other hardware:
**every offset comes out about 37 % too high**, and the trimmers cannot correct that. Use
firmware 1.4.2 on these boards for an offset that is right – see
[firmware-notes.md](firmware-notes.md#offset-and-amplitude-scaling). The amplitude is not
affected.

### Before turning anything

* Photograph or mark the current trimmer positions.
* Let the unit warm up for about 15 minutes.
* Measure into high impedance (DMM or 1 MΩ scope input), not into 50 Ω.
* Use a DMM for DC levels. A square wave at 0.1 Hz lets the DMM read the high and the low
  level directly.

### Step 1 – characterise

Per channel. The middle range covers amplitudes up to 5 Vpp and offsets up to ±2.5 V (with
peak + |offset| ≤ 3.5 V); the points marked "large" switch to the large range:

| Setting | Measured |
|---|---|
| DC, offset −1 V / 0 V / +1 V | |
| DC, offset −3 V / +3 V (large) | |
| square 0.1 Hz, offset 0, 1 / 2 / 3 / 4 / 5 Vpp: high / low | |
| square 0.1 Hz, offset 0, 10 Vpp (large): high / low | |
| square 0.1 Hz, 1 Vpp, offset +1 V: high / low | |

The DC series gives the zero error and the gain of the offset path, the square series the
amplitude gain and the symmetry (|high| vs. |low| around the offset). Read the levels of the
square wave with the DMM, not with the oscilloscope – the scope's cursors are not accurate
enough for this.

### Step 2 – find out what each trimmer does

Turn one trimmer by a small, defined amount (e.g. 1/8 turn), repeat one DC point (offset
0 V) and one square point (5 Vpp), note what moved, and turn it back.

### Step 3 – adjust

Typical order for this kind of output stage (confirm with step 2):

1. Offset trimmer: DC offset 0 V → 0.000 V.
2. Symmetry trimmer: square with offset 0 → |high| = |low|.
3. Amplitude trimmer: square 10 Vpp → high − low = 10.00 V.
4. Repeat 1–3 once (they interact), then check the DC series and the small/large ranges.

Errors the trimmers cannot remove (for example a gain error of the offset path) come from
the firmware's coefficients (see above). Reports with measurement series are welcome.

### Results on the test unit (so far)

FPGA board V2.1, CH1, firmware 1.8.0, Fluke 177 into high impedance:

| Point | Result |
|---|---|
| zero (DC 0 V) | +5 mV |
| offset path, middle range (DC ±1 V) | 1.347 V per volt: +35 % – firmware coefficient, see above |
| offset path, large range (DC ±3 V) | 1.376 V per volt: +38 % – firmware coefficient |
| amplitude 1 / 2 / 3 / 4 Vpp (middle) | 1.000 / 2.000 / 3.003 / 4.009 Vpp: within 0.2 % |
| amplitude 5 Vpp (middle) | 5.22 Vpp: +4.4 % – the firmware's code is linear, so this is the analog path at 90 % of the DAC reference |
| amplitude 10 Vpp (large) | 10.028 Vpp: +0.3 % |
| range switch | the relay clicks just above 5 Vpp |

Trimmer behaviour found so far: **W2 ("Offset") moves both the zero and the gain of the
offset path** – it is not a pure zero trimmer, and its range is far too small for the 37 %
of the firmware coefficient. W26, W5 and channel 2 have not been characterised yet.
