# Release files

| File | Content |
|---|---|
| `fy6900_fpga_v0.19.rbf` | FPGA bitstream v0.19 (Quartus raw binary for EP4CE6E22C8N) |
| `SHA256SUMS` | SHA-256 of the release files |

The `.rbf` is not programmed directly: insert it into a backup of **your own** flash with

```
python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.19.rbf patched.bin --board V2.1
python tools/fy6900_flash.py pof patched.bin patched.pof
```

(`--board` is the revision printed on your FPGA board – see
[Compatibility](../docs/installation.md#compatibility).)

and program `patched.pof` as described in [docs/installation.md](../docs/installation.md).
After patching, the bitstream area of the image (flash 0x000000–0x059FFF) has the SHA-256
`39d01d255e8fef65fd14ba924cc02235853a2f5760001dcf02943db86f0dd077`.

The bitstream is built from the sources in [`fpga/`](../fpga) without changes; a clean
compile with Quartus Prime 25.1 Lite reproduces it bit for bit.

## v0.19

Guarded flash writes: custom waveforms uploaded with the PC software are stored in the
flash. The flash size comes from the JEDEC ID (W25Q16 2 MB, W25Q32 4 MB); nothing is written
below 0x05A000 (bitstream area) or beyond the flash size, so the 1.8.0 slot layout can no
longer corrupt the flash. Details: [docs/fpga-design.md](../docs/fpga-design.md#flash-writes).
Tested on the V2.1 unit with a W25Q32 soldered in (test script and PC software upload); the
W25Q16 case (slots 25–64 refused) is verified in simulation, not yet on hardware.

## v0.18

Covers all functions listed in the [README](../README.md#status). Tested on an FY6900 60 MHz
with FPGA board V2.1, front panel board V2.2 and STM32 firmware 1.8.0, and confirmed on a
second unit with FPGA board V1.9 ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)).
