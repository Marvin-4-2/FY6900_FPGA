# Known bitstreams

`tools/fy6900_flash.py info <dump>` prints the SHA-256 of the bitstream area of a W25Q16
dump (flash 0x000000–0x059FFF). The `patch` command only accepts the bitstreams listed here
(the list is also in the tool).

| SHA-256 of flash 0x000000–0x059FFF | Bitstream | Model name | FPGA board revision | Front panel revision | Front panel firmware version | Notes |
|---|---|---|---|---|---|---|
| `89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5` | FeelTech stock (ID register 0x3A = 0x10) | FY6900-60M | V2.1 | V2.2 | 1.4.2, 1.8.0 | my unit: the stock bitstream never starts its DDS ([history.md](history.md#why-the-stock-bitstream-did-not-work)) |
| `89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5` | FeelTech stock (ID register 0x3A = 0x10) | FY6900-60M | V1.9 | V1.9 | 1.4.2| stock bitstream works (both channels) |
| `89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5` | FeelTech stock (ID register 0x3A = 0x10) | FY6900-60M | V1.9 | V1.9 | 1.8.0 | stock bitstream, saving a custom waveform corrupts the flash contents ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)) |
| `89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5` | FeelTech stock (ID register 0x3A = 0x10) | FY6900 | ? | ? | ? | identical in several dumps from other sources, revisions unknown |
| `f15cbb2f2eaa7d125e04360a7c7ef1715425b635f97692310a4733ebb36f2a4f` | this project, v0.18 | FY6900-60M | V2.1 | V2.2 | 1.8.0 | my unit, all functions tested |

For comparison: an FY6600 V3.1 dump has a different bitstream (different hardware).

## Please report

If you have an FY6900 – especially a **working** one with the stock bitstream – please open
an issue with the template
[**Bitstream report**](https://github.com/Marvin-4-2/FY6900_FPGA/issues/new?template=bitstream_report.yml).
It asks for:

* the output of `python tools/fy6900_flash.py info <your dump>`
* the revisions printed on the FPGA board and on the front panel board
* model (40/50/60 MHz) and STM32 firmware version (shown at start-up)
* whether the stock bitstream works on your unit

This helps to answer two open questions: which board revisions share this pin assignment
(so far V1.9 and V2.1), and what the stock bitstream of a **working V2.1 board** looks like.
The stock bitstream above works on FPGA board V1.9 with firmware 1.4.2 and 1.8.0, but not
on the V2.1 test unit, so V2.1 boards probably ship with a newer bitstream – most likely
one that reports the FPGA ID 0xFB69 in register 0x3A that firmware 1.8.0 asks for (see
[history.md](history.md#why-the-stock-bitstream-did-not-work)). A report from a working
V2.1 unit is the most wanted one.

Do not attach complete flash dumps to public issues – they contain FeelTech's waveform data;
the SHA-256 is enough.
