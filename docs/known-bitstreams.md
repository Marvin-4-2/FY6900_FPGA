# Known bitstreams

`tools/fy6900_flash.py info <dump>` prints the SHA-256 of the bitstream area of a W25Q16
dump (flash 0x000000–0x059FFF). The `patch` command only accepts the bitstreams listed here
(the list is also in the tool).

| SHA-256 of flash 0x000000–0x059FFF | Bitstream | Units / boards |
|---|---|---|
| `89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5` | FeelTech stock (ID register 0x3A = 0x10) | FY6900 60 MHz, FPGA board V2.1, front panel V2.2 (test unit); identical in several dumps from other sources |
| `f15cbb2f2eaa7d125e04360a7c7ef1715425b635f97692310a4733ebb36f2a4f` | this project, v0.18 | – |

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

This helps to answer two open questions: which board revisions share this pin assignment,
and whether there is a newer stock bitstream (firmware 1.8.0 checks for an FPGA ID of
0xFB69 in register 0x3A, which the stock bitstream above does not report – see
[history.md](history.md#why-the-stock-bitstream-did-not-work)).

Do not attach complete flash dumps to public issues – they contain FeelTech's waveform data;
the SHA-256 is enough.
