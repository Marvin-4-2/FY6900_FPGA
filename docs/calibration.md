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

### Before turning anything

* Photograph or mark the current trimmer positions.
* Let the unit warm up for about 15 minutes.
* Measure into high impedance (DMM or 1 MΩ scope input), not into 50 Ω.
* Use a DMM for DC levels. A square wave at 0.1 Hz lets the DMM read the high and the low
  level directly.

### Step 1 – characterise

Per channel, in the middle range (no setting below about 0.35 V or above about 3.5 V):

| Setting | Measured |
|---|---|
| DC, offset −3 V / −1 V / 0 V / +1 V / +3 V | |
| square 0.1 Hz, offset 0, 2 Vpp: high / low | |
| square 0.1 Hz, offset 0, 5 Vpp: high / low | |
| square 0.1 Hz, offset 0, 10 Vpp: high / low | |

The DC series gives the zero error and the gain of the offset path, the square series the
amplitude gain and the symmetry (|high| vs. |low| around the offset).

### Step 2 – find out what each trimmer does

Turn one trimmer by a small, defined amount (e.g. 1/8 turn), repeat one DC point (offset
0 V) and one square point (5 Vpp), note what moved, and turn it back.

### Step 3 – adjust

Typical order for this kind of output stage (confirm with step 2):

1. Offset trimmer: DC offset 0 V → 0.000 V.
2. Symmetry trimmer: square with offset 0 → |high| = |low|.
3. Amplitude trimmer: square 10 Vpp → high − low = 10.00 V.
4. Repeat 1–3 once (they interact), then check the DC series and the small/large ranges.

Errors the trimmers cannot remove (for example a gain error of the offset path) would have
to be corrected in the firmware's calibration data. Reports with measurement series are
welcome.
