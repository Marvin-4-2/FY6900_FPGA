# FY6900_FPGA

An open-source replacement FPGA design for the **FeelTech / FeelElec FY6900** dual-channel
function generator. It re-implements the register interface of the original FPGA bitstream,
so the **stock STM32 firmware and its complete user interface keep working unchanged** –
only the bitstream in the generator's SPI flash is replaced.

It was written to repair a unit whose stock bitstream never started its DDS (no waveform on
either channel although all hardware was fine). It now covers every function of the
generator that involves the FPGA.

> **Tested hardware:** FY6900 60 MHz, **FPGA board V2.1**, **front panel board V2.2**,
> STM32 firmware **1.8.0**. Other revisions may differ – read [Compatibility](#compatibility)
> before flashing.

## Status

Version **0.18**. Everything below was tested on the unit unless marked otherwise.

| Area | Function | Status |
|---|---|---|
| Waveforms | sine and all table waveforms (loaded from the flash), square/rectangle with duty, trapezoid, CMOS/PWM, Adj-Pulse (fixed pulse width), DC, channel on/off | ✅ |
| | 125 MSPS DDS, up to 60 MHz, 48-bit phase accumulator | ✅ |
| | square edges interpolated between samples (jitter ≈ 0.7 ns instead of 8 ns) | ✅ |
| Output | amplitude, offset, range relays, phase between the channels | ✅ |
| Modulation (CH1) | AM, FM, PM, FSK, ASK, PSK, BURST | ✅ |
| | sources CH2, Ext.(AC) = Counter input, Ext.(DC) = Trig IN, MANU (OK key), Ext.(VCO-IN) | ✅ |
| Sweep | frequency/amplitude/offset/duty (runs in the firmware) | ✅ |
| Counter | frequency (gate 1/10/100 s), period, +/− width, duty, event count; inputs Counter (AC) and Trig IN (DC) | ✅ |
| Rear I/O | TTL Port A–D (CH1/CH2, 0°/180°), Sync OUT | ✅ |
| | uplink master/slave (multi-unit synchronisation) | ✅ slave tested with a loop-back, master simulated |
| Calibration | frequency calibration (hidden "OSCI" menu) acts on generator and counter | ✅ implemented, regression tested; not yet calibrated against a reference |
| Start-up | no 4–5 s ID wait with firmware 1.8.0 | ✅ |
| Waveform upload | storing arbitrary waveforms in the flash (PC software) | 🔜 future extension – see [Roadmap](#roadmap) |

## How it works

```
 STM32 front panel ──SPI──> FPGA (this design) ──> 2 × DAC-1412 ──> output amplifiers ──> CH1, CH2
   (stock firmware)          │  register interface, 2 × DDS @ 125 MSPS,
                             │  modulation, counter, TTL/sync, calibration
                             └──> W25Q16 SPI flash (bitstream + waveform tables)
```

The FPGA (Cyclone IV E EP4CE6E22C8N) receives all settings from the STM32 over SPI, loads
the selected waveforms from the SPI flash into its wave RAMs and generates both channels with
48-bit DDS at 125 MSPS. See [docs/fpga-design.md](docs/fpga-design.md).

## Quick start

1. Back up the W25Q16 flash of your unit (2 MB) and keep the backup.
2. Check it: `python tools/fy6900_flash.py info backup.bin` – it must report the known stock
   bitstream.
3. Patch it: `python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.18.rbf patched.bin`
4. Convert it: `python tools/fy6900_flash.py pof patched.bin patched.pof`
5. Program `patched.pof` with a USB-Blaster through the 10-pin header ("Active Serial
   Programming", EPCS16) while the generator is switched on.

The full procedure, including how to restore the original, is in
**[docs/installation.md](docs/installation.md)**.

## Compatibility

The design only works on boards with exactly this FPGA pin assignment
([docs/pinout.csv](docs/pinout.csv)). The stock bitstream in the flash is a good fingerprint:
several FY6900 dumps from different sources contain the identical stock bitstream, and the
patch tool refuses dumps with an unknown one. A wrong pin assignment can make the FPGA drive
against other outputs on the board. See [docs/known-bitstreams.md](docs/known-bitstreams.md).

The 40/50 MHz models share the hardware family but were not tested.

## Repository layout

| Path | Content |
|---|---|
| [`fpga/`](fpga) | Quartus project: `fy_fpga.v` (top level, DDS channel, frequency conversion, MCP4822 driver), `freq_counter.v`, constraints, pin assignments, sine table generator |
| [`fpga/sim/`](fpga/sim) | self-checking testbenches and run scripts (Questa) |
| [`tools/fy6900_flash.py`](tools/fy6900_flash.py) | check, patch and convert flash images (`info`, `patch`, `pof`, `unpof`) |
| [`tools/sim_edge_interp.py`](tools/sim_edge_interp.py) | model of the square-wave edge interpolation |
| [`sniffer/`](sniffer) | Raspberry Pi Pico SPI sniffer for the STM32 ↔ FPGA bus |
| [`release/`](release) | prebuilt bitstream with checksums |
| [`docs/`](docs) | documentation (see below) |

## Documentation

| Document | Content |
|---|---|
| [installation.md](docs/installation.md) | backup, patching, programming, restoring |
| [hardware.md](docs/hardware.md) | board overview, signal path, connectors, pin summary, programming header |
| [pinout.csv](docs/pinout.csv) | all 144 FPGA pins |
| [spi-protocol.md](docs/spi-protocol.md) | STM32 ↔ FPGA transport |
| [registers.md](docs/registers.md) | complete register map |
| [firmware-notes.md](docs/firmware-notes.md) | relevant behaviour of the stock firmware (1.4.2 / 1.8.0) |
| [fpga-design.md](docs/fpga-design.md) | architecture of the FPGA design, limitations |
| [calibration.md](docs/calibration.md) | frequency calibration and analog trimmers |
| [simulation.md](docs/simulation.md) | building, testbenches |
| [sniffer.md](docs/sniffer.md) | SPI sniffer |
| [known-bitstreams.md](docs/known-bitstreams.md) | bitstream fingerprints, call for dumps |
| [history.md](docs/history.md) | how the project came about, and why the stock bitstream failed |

## Building from source

```
cd fpga
quartus_sh --flow compile fy_fpga
```

Quartus Prime Lite with Cyclone IV E support (developed with 25.1). The resulting
`fy_fpga.rbf` is used with `tools/fy6900_flash.py patch`. The repository source of v0.18
builds a bitstream identical to [`release/fy6900_fpga_v0.18.rbf`](release). Testbenches:
`fpga/sim/run_all.sh` – see [docs/simulation.md](docs/simulation.md).

## Roadmap

* **Waveform upload (flash writes).** The PC software stores arbitrary waveforms in the
  generator's SPI flash through the FPGA (sector erase and byte programming via registers
  0x11, 0x13, 0x14, 0x16). This design currently ignores these registers, so stored
  waveforms can be used but not changed. What is known about the protocol and how it could
  be implemented safely is described in
  [docs/fpga-design.md](docs/fpga-design.md#future-extension-flash-writes).
* Analog calibration data for the trimmers (measurement series welcome).

## Contributing

* **Flash dump fingerprints:** please report the output of `tools/fy6900_flash.py info` with
  your board revisions using the issue template **"Bitstream report"** – especially from units
  where the stock bitstream works ([known-bitstreams.md](docs/known-bitstreams.md)). Do not
  publish complete dumps.
* **Bugs:** issue template **"Bug report"**.
* **Questions, test reports and experiences** from other units, firmware versions and models:
  [Discussions](https://github.com/Marvin-4-2/FY6900_FPGA/discussions).
* **Implementations** of the [roadmap](#roadmap) items – please run the testbenches
  (`fpga/sim/run_all.sh`) and check the timing summary before opening a pull request.

## Disclaimer

This is an independent project, not affiliated with or endorsed by FeelTech/FeelElec.
FY6900 is a product name of its manufacturer. Use at your own risk: the generator has to be
opened and programmed while it is switched on. The repository contains no firmware,
bitstream or data of the manufacturer; it only contains interface information obtained
for interoperability and an independently written FPGA design.

## License

Copyright 2026 The FY6900_FPGA contributors.

This project is licensed under the **CERN Open Hardware Licence Version 2 – Strongly
Reciprocal** ([CERN-OHL-S-2.0](LICENSE)). You may use, study, modify and distribute it and
make products with it; if you distribute modified versions or products based on it, you
must make the complete corresponding source available under the same licence.

Source location: <https://github.com/Marvin-4-2/FY6900_FPGA>

Every source file carries the SPDX identifier `CERN-OHL-S-2.0`.
