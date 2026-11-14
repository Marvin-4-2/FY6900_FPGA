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

Function 0x08011C64 (1.4.2) selects the range per channel from amplitude and offset. The
firmware keeps the amplitude in units of 0.1 mV (peak to peak) and the offset in mV; written
as voltages:

| Bits | Range | Condition |
|---|---|---|
| `01` | small (attenuator) | peak + \|offset\| ≤ 0.35 V and amplitude ≤ 0.5 Vpp and \|offset\| ≤ 0.25 V |
| `10` | large (gain) | peak + \|offset\| > 3.5 V or amplitude > 5 Vpp or \|offset\| > 2.5 V (and f ≤ 20 MHz) |
| `00` | middle | otherwise |

CMOS and Adj-Pulse count twice the amplitude (they are unipolar). On every change the
firmware sets the amplitude to 0, writes reg 0x05 repeatedly and ramps the amplitude up.
(On the test unit the relay clicks just above 5 Vpp, as the rule says.)

## Offset and amplitude scaling

The firmware computes the 12-bit MCP4822 codes itself; the FPGA passes them through
unchanged (CH1 offset code: 0x08012466 in 1.8.0, 0x08011EDC in 1.4.2).

| Range | Offset code (0x29 / 0x2A) | Amplitude code (0x2B / 0x2C) |
|---|---|---|
| small | 0x7FF + offset[mV] × 2047 / 250 × F_1x | amplitude × 4095 × 0.9 / 0.5 Vpp |
| middle | 0x7FF + offset[mV] × 2047 / 2500 × F_1x | amplitude × 4095 × 0.9 / 5 Vpp |
| large | 0x7FF + offset[mV] × 0.2047 × F_4x | amplitude × 4095 × 0.9 / 24 Vpp (very large amplitudes use another factor) |

The amplitude scaling is identical in 1.4.2 and 1.8.0. The offset uses a **coefficient per
channel and range** ("XISHU", Chinese for coefficient): F_1x for the small and the middle
range, F_4x for the large range (the output gain of the large range is about 4×).

1.8.0 loads the coefficients at start-up (0x08011DA8) from its configuration block in the SPI
flash (at 0x190000, words at +0x6E8 … +0x6F4, stored as coefficient × 10000). An erased word
keeps the compiled-in default:

| Coefficient | Default 1.4.2 | Default 1.8.0 | Ratio |
|---|---|---|---|
| F_1x (small, middle) | 0.644 | 0.8844 | 1.373 |
| F_4x (large) | 0.534 | 0.7501 | 1.405 |

**Consequence on boards V1.9 / V2.1:** a flash with the original (1.4.2) layout has no 1.8.0
configuration block, so 1.8.0 uses its defaults. On the test unit (FPGA board V2.1, firmware
1.8.0) a set offset of +1 V gave 1.35 V and +3 V gave 4.11 V – **+35 % and +38 %**, exactly
the ratio of the defaults. 1.8.0's defaults evidently belong to newer hardware whose
per-unit values are stored in the configuration block. The analog trimmers cannot
compensate this (the offset trimmer of the test unit reached its end stop); with **firmware
1.4.2** the offset is expected to be correct within about 2 %. The waveform amplitude is not
affected.

1.8.0 contains a factory calibration for these coefficients: the UART commands
`CH11XISHU`, `CH14XISHU`, `CH21XISHU` and `CH24XISHU` (channel 1/2, 1× = middle, 4× = large
range) pass a measured value – the raw bits of a float, written in decimal – taken at the
nominal offset (1 V in the middle range, 10 V in the large range); the firmware sets
F_new = F_old × nominal / measured. A long press on a front panel key does the same with the
offset value entered on the display. The new values are saved to the configuration block;
whether that works without an existing block (as on a flash with the original layout) has
not been checked. None of this has been tried on the unit.

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
n = 1…64, terminated by `\n`); the unit answers `W`, receives exactly 16384 bytes – 8192
samples × 14 bit, little endian, **plain** – and answers `H` when it starts saving, then `N`
when done or `E` if the address check fails. The firmware computes a flash address for the
slot, checks it, erases four 4 KB sectors and passes the 16384 bytes unchanged to the FPGA
(registers 0x17, 0x11, 0x16, 0x14, 0x13, 0x15 – see
[fpga-design.md](fpga-design.md#flash-writes)). The stock FPGA bit-permutes
every byte into the flash format when it writes it. This is the only place where the firmware
writes waveform data to the SPI flash.

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
the chip. In addition, the stock bitstream **protects the start of the flash**: it replaces
every address below a limit – somewhere between 0x008000 and 0x058000 – by the fixed address
0x1B0000 (1.8.0 slot 5). This also applies to the four sector erases, so only
0x1B0000–0x1B0FFF is erased and the rest of the slot is programmed over its old content.

Measured on the test unit (FPGA board V2.1, W25Q16, stock bitstream, firmware 1.8.0; uploads
with the PC software and with a test script that sends `DDS_WAVE<n>` directly):

| 1.8.0 slot | Address sent | Wrapped | What happens | Measured with |
|---|---|---|---|---|
| 1–24 | 0x1A0000–0x1FFFFF | – | written normally (1.4.2 slots 41–64) | slots 1, 2 |
| 25 … limit | 0x200000 … | 0x000000 … | **protected:** redirected to 0x1B0000 – the bitstream is safe, but **slot 5 is damaged** (only its first 4 KB are erased) | slots 25, 26 |
| limit … 47 | … 0x25BFFF | … 0x05BFFF | **overwrites the end of the FPGA bitstream** (it ends at 0x059D4F) | slot 47 |
| 48–64 | 0x25C000–0x29FFFF | 0x05C000–0x09FFFF | written into the empty gap and **the first 16 built-in waveforms of 1.4.2** (0x60000–0x9FFFF); 1.8.0 does not use them | slot 48 |

The protection limit lies between slot 27 (0x008000) and slot 46 (0x054000); it was not
narrowed down further. Slots 48–64 even seem to work with 1.8.0 – it reads the slot back
through the same wrapped address – but they destroy the built-in waveforms of 1.4.2, which
shows only after going back to 1.4.2. Every upload is acknowledged with `N`, so the user gets
no warning. The firmware writes nothing to the flash at power-on.

A destroyed bitstream shows only after the next power-on, because the FPGA keeps running
until then. With firmware 1.8.0 the unit then takes a long time to start, the CH1 display
appears first and the CH2 display much later, the waveform display shows a flat DC line, and
switching the waveform hangs the unit. The flash can be restored with the USB-Blaster as
usual.

This matches the report that saving a custom waveform with 1.8.0 corrupts the flash
([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)). The reporter's unit has a W25Q32JV – the corruption happened anyway, because
the original design wraps every address at 2 MB (see below).

**The wrap-around happens in the stock FPGA.** The same test with a 4 MB W25Q32 soldered into
the test unit gave the same result: slot 48 landed at 0x05C000 and slot 25 at 0x1B0000, the
bitstream stayed intact. The stock bitstream uses only 21 address bits (2 MB), and its
protection works on the wrapped address. A bigger flash alone therefore does not make 1.8.0
safe; units that ship with a W25Q32 must have a different, probably newer, stock bitstream.

**With firmware 1.8.0 and the stock bitstream, upload custom waveforms only to slots 1–24**
(or upload them with 1.4.2), and keep a backup of the flash. This project's bitstream (from
v0.19) stores uploads behind a write guard: it never writes below 0x05A000 or beyond the
flash size. With 1.8.0 on a 2 MB flash it stores slots 1–24 and refuses slots 25–64 (the
firmware still reports success); with a 4 MB W25Q32 all 64 slots work – see
[fpga-design.md](fpga-design.md#flash-writes).

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
| offset coefficients without a configuration block | 0.644 / 0.534 | 0.8844 / 0.7501 – offset 37 % too high on V1.9 / V2.1 boards, see [above](#offset-and-amplitude-scaling) |

Everything else – register numbers, amplitude scaling, modulation, counter – is identical.
