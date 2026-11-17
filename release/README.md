# Release files

| File | Content |
|---|---|
| `fy6900_fpga_v0.21.rbf` | FPGA bitstream v0.21 (Quartus raw binary for EP4CE6E22C8N) |
| `SHA256SUMS` | SHA-256 of the release files |

The `.rbf` is not programmed directly: insert it into a backup of **your own** flash with

```
python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.21.rbf patched.bin --board V2.1
python tools/fy6900_flash.py pof patched.bin patched.pof
```

(`--board` is the revision printed on your FPGA board – see
[Compatibility](../docs/installation.md#compatibility).)

and program `patched.pof` as described in [docs/installation.md](../docs/installation.md).
After patching, the bitstream area of the image (flash 0x000000–0x059FFF) has the SHA-256
`3b1e79607b2f9a57427d7f1b074e51de7f9029402fbce432c4d9b9df52b6e9fb`.

The bitstream is built from the sources in [`fpga/`](../fpga) without changes; a clean
compile with Quartus Prime 25.1 Lite reproduces it bit for bit.

## v0.21

250 MSPS: the DACs now run at 250 MSPS like in the original design (two samples per 125 MHz
clock, DDR output registers, 250 MHz DAC clocks). At 125 MSPS a sine above about 40 MHz came
with an image at 125 MHz − f that the board's output filter barely removes – at 60 MHz the
output looked amplitude-modulated with 5 MHz. Now the 60 MHz sine is clean, and the
sin(x)/x roll-off at 60 MHz drops from −3.6 dB to −0.8 dB. Tested on the V2.1 unit (sine up
to 60 MHz with the scope's FFT, AM up to 60 MHz, custom waveforms, upload and switching,
channel phase, Port A, counter, burst, FM/FSK/PSK, all waveform types, frequency digits) and
with all testbenches (117 checks, including the new `tb_250`). Everything else as in v0.20.

## v0.20

Frequency fix: the firmware sends a frequency as 0.1 Hz units plus the remainder in µHz
(two decimal parts, not one binary number). Up to v0.19 any digit below 0.1 Hz made the
frequency jump (to above 40 MHz); now all digits down to 1 µHz work – carrier CH1/CH2, FM
deviation and FSK hop frequency. Tested on the V2.1 unit, with a bit-accurate model of the new
conversion and with all testbenches (107 checks, including six new frequency checks in
`tb_spi`). Everything else as in v0.19.

## v0.19

Guarded flash writes: custom waveforms uploaded with the PC software are stored in the
flash. The flash size comes from the JEDEC ID (W25Q16 2 MB, W25Q32 4 MB); nothing is written
below 0x05A000 (bitstream area) or beyond the flash size, so the 1.8.0 slot layout can no
longer corrupt the flash. Details: [docs/fpga-design.md](../docs/fpga-design.md#flash-writes).
Tested on the V2.1 unit with a W25Q32 soldered in (test script and PC software upload) and
confirmed by a user on a V1.9 unit with a factory-fitted W25Q32JV (all 64 slots, all
functions, [#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)); the W25Q16 case (slots 25–64 refused) is verified in simulation, not
yet on hardware.

## v0.18

Covers all functions listed in the [README](../README.md#status). Tested on an FY6900 60 MHz
with FPGA board V2.1, front panel board V2.2 and STM32 firmware 1.8.0, and confirmed on a
second unit with FPGA board V1.9 ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)).
