# Notes on the stock STM32 firmware

The replacement FPGA has to behave exactly like the original towards the unchanged STM32
firmware. This page collects the firmware behaviour that matters for that. It was derived
from disassemblies of the firmware versions **1.4.2** and **1.8.0** and confirmed with the
[SPI sniffer](sniffer.md). The target version is **1.8.0**; 1.4.2 writes the same registers
except where noted.

Addresses refer to the STM32 flash (base 0x08000000) of firmware 1.8.0 unless stated
otherwise.

## Power-on sequence (1.8.0, 0x08016214)

1. Up to 200 times, 20 ms apart: write `05 = 0`, `21 = 0x10`, offsets `29/2A = 0x800/0x7FF`,
   amplitudes `2B/2C = 1/0`, read `3A` twice. The loop ends when bits 23:8 of reg 0x3A equal
   `0xFB69` twice in a row. The original bitstream returns 0x10 here, so the loop always ran
   the full 4–5 s; this design returns `0x00FB6910`.
2. `28 = 0`, read `3A` twice. The firmware stores `(value & 0xFF) | 0xFB6900`; bits 19:16 = 0xB
   select the waveform flash addresses (independent of what the FPGA returns).
3. `28 = 1` twice, `00 = 0` twice (dummy writes), then poll `R 1F & 0x1F == 0x10` (up to 100×).
4. Waveform transfers, reference registers 0x22–0x27, `21 = 0x10`, channel parameters.

Firmware 1.4.2 has no 0x3A poll loop (it only stores the value).

## Authentication

Both firmware versions run a challenge/response handshake at start-up: they read 16
challenge bytes (index in 0x0E, data from 0x1B), compute responses from a 16-byte key and
write them to 0x1C with strobes on 0x1A. With the stock configuration data the key is
derived from the STM32's unique device ID. A bitstream that is identical in every unit
cannot verify such a device-specific response, and the firmware does not evaluate any
result. This design ignores the handshake (0x1B reads 0); the firmware works normally.

## Output range (0x05 bits 3:0)

Function 0x08011C64 (1.4.2) selects the range per channel from amplitude and offset:

| Bits | Range | Condition (values in mV) |
|---|---|---|
| `01` | small (attenuator) | Amp/20 + \|Offset\| ≤ 350 and Amp ≤ 5000 and \|Offset\| ≤ 250 |
| `10` | large (gain) | Amp/20 + \|Offset\| > 3500 or Amp > 50000 or \|Offset\| > 2500 (and f ≤ 20 MHz) |
| `00` | middle | otherwise |

CMOS and Adj-Pulse count twice the amplitude (they are unipolar). On every change the
firmware sets the amplitude to 0, writes reg 0x05 repeatedly and ramps the amplitude up.

## Frequency counter

* Mode change: bits 2:1 of reg 0x01 are first written as 00, then 01 (FREQU) or 11 (COUNT).
* FREQU: the firmware polls reg 0x03 regularly. When bit 1 (gate running) is 0 it reads the
  frequency from 0x02 (select 00) and restarts the gate (bit 1: 0 → 1).
* When bit 0 (widths ready) is 1 it reads −width (select 01) and +width (select 11) and
  restarts the width measurement (bit 0: 0 → 1). Widths are displayed as value × 4 ns.
* COUNT: reg 0x02 is read continuously; ZERO restarts the count.
* COUPLING switches reg 0x05 bit 4: AC = "MEASURE <- Counter", DC = "MEASURE <- Trig IN".
  There is no coupling switch in hardware – the two settings select different inputs.

## Modulation (0x08018C64 in 1.4.2, 0x0801944C in 1.8.0)

Modes in the menu: FSK, ASK, PSK, BURST, AM, FM, PM. Modulation always acts on CH1. The
internal source is CH2: the CH2 waveform modulates CH1 while CH2 is still output normally.

| Mode | Register writes |
|---|---|
| FSK | `21 |= 0x02`, `20` = hop frequency low, `1E` = high, `21 |= 0x80` |
| ASK | `21 |= 0x04` |
| PSK | `21 |= 0x01` |
| BURST | `21 = 0x10`, `19 = count | (source + 1) << 20` |
| AM | `21 |= 0x08` (+ 0x10 for Ext.(VCO-IN)), `2E = depth · 2047 / 2000` |
| FM | `21 |= 0x20` (+ 0x10), `20`/`1E` = deviation, then `21 |= 0x80` |
| PM | `21 |= 0x40` (+ 0x10), `36 = BIAS · 3.640861` |

* Sources: FSK/ASK/PSK/BURST offer CH2, Ext.(AC), MANU, Ext.(DC); AM/FM/PM offer CH2 and
  Ext.(VCO-IN).
* The menu's "BIAS" value is the PM deviation.
* Sweep (frequency, amplitude, offset, duty) runs entirely in the firmware, which simply
  keeps writing the normal parameter registers.

### MANU (OK key)

* FSK/ASK/PSK: `18 = 0` when OK is pressed, `18 = 1` when it is released (level keying).
* BURST: `18 = 0` followed immediately by `18 = 1` (edge trigger).
* **Firmware 1.8.0 only:** when MANU is selected the firmware writes `19 = (source+1) << 20`
  with **count 0** and pulses 0x18; the OK key first writes the real count, then pulses
  0x18. The FPGA must therefore treat count 0 as "armed but silent" – an implementation that
  treats 0 as "endless" starts a burst that never stops.
* The UART command parser can trigger the same pulse remotely.

### Ext.(VCO-IN)

When AM/FM/PM use the external source, the firmware writes `2D = 0x800`, leaves REGSEL high
and then sends the STM32 ADC value of the VCO-IN socket (×1.1, limited to 4095) in 16-bit
frames without an address in every main-loop iteration (1.8.0: 0x08016488). See
[spi-protocol.md](spi-protocol.md#vco-in-frames).

Hardware path: VCO-IN socket → JRC4558 voltage follower → 1 kΩ → front panel connector →
divider (≈ 0.6) → STM32 PA0 (ADC1 channel 0, continuous conversion with DMA). Measured input
range: **0–5 V, 2.5 V = no modulation**; an open input reads 0 V = full negative deviation.

## Uplink (0x08011878)

Menu SYS → CONF → M/S (master/slave) and UPLI (on/off), or the UART commands `UUL` and `UMS`.
The firmware encodes the state in reg 0x05 bits 6:5: `10` off, `00` master, `11` slave.
According to the user manual one master and up to eight slaves are connected in parallel
through their SYNC sockets and "work synchronously according to the start phase of the
master". The manual also recommends switching the uplink off while using the counter.

## Frequency calibration (0x08011E20)

The reference value X is loaded from the configuration (or 10 000 000 if none is stored)
and written as `24 = 5·X`, `25 = 50·X`, `26:27 = 500·X`, `22:23 = 25 000 000·X`. The hidden
calibration menu changes X, see [calibration.md](calibration.md).

## Channel switched off

The firmware sets mode 7 in reg 0x04 and the offset to the centre (0x7FF) for a channel that
is switched off, and clears bit 8 (CH1) or bit 7 (CH2) in reg 0x05. No relay is switched.

## Custom waveform upload

The PC software uploads an arbitrary waveform with the UART command `DDS_WAVE<n>` (slot
n = 1…64) followed by 16 KB of data. The firmware computes a flash address for the slot,
checks it, erases four 4 KB sectors and programs the 16384 bytes through the FPGA (registers
0x17, 0x11, 0x16, 0x14, 0x13, 0x15 – see
[fpga-design.md](fpga-design.md#future-extension-flash-writes)). This is the only place where
the firmware writes waveform data to the SPI flash.

| | 1.4.2 | 1.8.0 |
|---|---|---|
| Command handler | 0x0801510C | 0x08015740 |
| Slot address | 0x100000 + (n−1)·0x4000 | base + (n−1)·0x4000, base = 0x1A0000 |
| Slots 1–64 | 0x100000–0x1FFFFF (upper half of the 2 MB W25Q16) | 0x1A0000–**0x29FFFF** |
| Range check (save routine) | 0x5FFFE ≤ address ≤ 0x200000 (0x08016B14) | 0xFFFFE ≤ address ≤ 0x2A0000 (0x0801724C) |

In 1.8.0 the base addresses are variables. At start-up (0x0801308C) the firmware sets them
to 0xFC000, 0x1A0000 and 0x190000 if bits 19:16 of the stored FPGA ID are 0xB – which is
always the case, because the ID is stored as `(value & 0xFF) | 0xFB6900` (see the power-on
sequence above). This layout needs a flash of at least 4 MB (for example a W25Q32); it does
not fit the 2 MB W25Q16 of the FY6900 described here.

The built-in waveforms are in different places, too (read routine 0x0800F3A4 in 1.8.0):
1.4.2 loads them from 0x60000–0xDFFFF, 1.8.0 from 0x100000–0x17FFFF. In the stock flash that
second area holds copies of the 0x60000 set (it is the area of 1.4.2's custom slots 1–32),
which is why the built-in waveforms also work with 1.8.0. 1.8.0 never reads 0x60000–0xDFFFF.

On a unit with the 2 MB W25Q16 an address of 0x200000 or more wraps around to the start of
the chip:

| 1.8.0 slot | Address sent | Lands at | Effect |
|---|---|---|---|
| 1–24 | 0x1A0000–0x1FFFFF | same | slots 41–64 of the 1.4.2 layout – probably harmless |
| **25–47** | 0x200000–0x25BFFF | 0x000000–0x05BFFF | **erases and overwrites the FPGA bitstream** |
| **48–64** | 0x25C000–0x29FFFF | 0x05C000–0x09FFFF | **overwrites the first 16 built-in waveforms of 1.4.2** (0x60000–0x9FFFF); 1.8.0 does not use them |

The generator keeps working until it is switched off, because the FPGA is already
configured; after the next power-on the FPGA does not start (slots 25–47). Slots 48–64 even
seem to work with 1.8.0 – it reads the slot back through the same wrapped address – but they
destroy the built-in waveforms of 1.4.2, which shows only after going back to 1.4.2. This
matches the report that saving a custom waveform with 1.8.0 corrupts the flash
([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)).

**Measured** on the test unit (FPGA board V2.1, W25Q16, stock bitstream, firmware 1.8.0):
the firmware writes nothing to the flash at power-on; an upload to slot 1 changed exactly
0x1A0000–0x1A3FFF, an upload to slot 48 exactly 0x05C000–0x05FFFF – wrapped around from
0x25C000 as predicted. (Slot 48 was chosen because its wrapped address lies in the empty gap
between the bitstream and the waveforms.) The stock bitstream's flash writes work on this
board even though its DDS never starts. Still open: whether the address wraps in the
W25Q16 or already in the stock FPGA – the same test on a unit with a 4 MB W25Q32 would show
it.

**With firmware 1.8.0 and the stock bitstream, upload custom waveforms only to slots 1–24**
(or upload them with 1.4.2), and keep a backup of the flash. This project's bitstream
currently ignores flash writes, so with it an upload cannot damage the flash (but is not
stored either).

The only other routine that writes to the SPI flash (0x0800B900 in 1.8.0, 0x0800B680 in
1.4.2) stores data derived from the STM32 unique ID. It only runs if the bytes 0xA5/0x5A are
present at the start of a configuration block – at 0x190000 in 1.8.0, at 0xF0000 in 1.4.2 –
which is not the case in the stock flash layout. In 1.8.0 this routine lacks one 1 → 0 pulse
on register 0x16 that 1.4.2 sends before its second write loop.

## Differences 1.4.2 → 1.8.0 that matter for the FPGA

| Topic | 1.4.2 | 1.8.0 |
|---|---|---|
| reg 0x3A at power-on | read and stored | polled for 0xFB69 (up to 4–5 s) |
| MANU source | count written immediately | count 0 when selected, count written by OK |
| reg 0x05 | 8 bits (normal value 0xC0) | 9 bits (normal value 0x1C0), bits 8/7 = output on |
| built-in waveforms | 0x60000–0xDFFFF | 0x100000–0x17FFFF (copies in the stock flash) – irrelevant for the FPGA, it loads from the address it is given |
| custom waveform slots | 0x100000–0x1FFFFF | 0x1A0000–0x29FFFF – beyond the 2 MB flash, see [above](#custom-waveform-upload) |

Everything else – register numbers, scaling, modulation, counter – is identical.
