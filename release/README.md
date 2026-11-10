# Release files

| File | Content |
|---|---|
| `fy6900_fpga_v0.18.rbf` | FPGA bitstream v0.18 (Quartus raw binary for EP4CE6E22C8N) |
| `SHA256SUMS` | SHA-256 of the release files |

The `.rbf` is not programmed directly: insert it into a backup of **your own** flash with

```
python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.18.rbf patched.bin --board V2.1
python tools/fy6900_flash.py pof patched.bin patched.pof
```

(`--board` is the revision printed on your FPGA board – see
[Compatibility](../docs/installation.md#compatibility).)

and program `patched.pof` as described in [docs/installation.md](../docs/installation.md).
After patching, the bitstream area of the image (flash 0x000000–0x059FFF) has the SHA-256
`f15cbb2f2eaa7d125e04360a7c7ef1715425b635f97692310a4733ebb36f2a4f`.

The bitstream is built from the sources in [`fpga/`](../fpga) without changes; a clean
compile with Quartus Prime 25.1 Lite reproduces it bit for bit.

## v0.18

Covers all functions listed in the [README](../README.md#status). Tested on an FY6900 60 MHz
with FPGA board V2.1, front panel board V2.2 and STM32 firmware 1.8.0.
