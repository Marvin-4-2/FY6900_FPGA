# How this project came about

This is the story of the reverse engineering and the development, from a dead generator to a
complete replacement FPGA design. The final state is described in the other documents; this
page explains how it was reached and why some design decisions look the way they do.

## The starting point

The unit (FY6900 60 MHz, FPGA board V2.1, front panel V2.2) arrived with a dead STM32. The
front panel was brought back to life with the tools of **gamerpaddy** – his firmware update
script [`updateFW.py`](../third_party/gamerpaddy) and his
[custom front panel firmware](https://github.com/gamerpaddy/fy6900-customfirmware) project
(see [Acknowledgements](../README.md#acknowledgements)). After the STM32 firmware was
restored (versions 1.4.2 and later 1.8.0 were used), the user interface worked again – but
**neither channel produced a waveform**. Only the offset
changed when settings were changed.

Measurements with the stock firmware and the stock bitstream showed:

* the 10 MHz TCXO signal reached the FPGA clock input (pin 23),
* the PLL supplies were present,
* the DAC-1412 data lines carried a **static value** – the first sample of the selected
  waveform – and changed only when a different waveform was selected,
* the **DAC clock was completely dead**.

## Is the hardware broken?

Several hypotheses about the clock path had to be ruled out first. A scope measurement
suggested a 5 Vpp sine with a large DC offset at the FPGA clock pin – implausible for a
3.3 V TCXO and caused by the probe setup (1× probe bandwidth, long ground lead). The
decisive test was to load **own test bitstreams** into the SPI flash:

1. PLL ×5 (50 MHz) – locked, a pin toggled at 1 kHz (which turned out to drive a relay).
2. PLL ×25 (250 MHz) and a 610 Hz sawtooth to the CH1 DAC – a clean sawtooth appeared at
   the op-amp output once the MCP4822 was programmed.

So the complete chain TCXO → PLL → FPGA I/O → DAC → output amplifier worked. The hardware
was fine; the stock bitstream simply did not start its DDS on this unit.

## What does the stock bitstream do?

By compiling own designs with varied PLL parameters and diffing the bitstreams, the PLL
configuration bits of the stock bitstream were located and decoded: **identical** to the
working 250 MHz test (M = 50, N = 1, VCO 500 MHz, input CLK1, no reset). The failure had to
be a logic-level condition inside the stock design.

## Reverse engineering the interface

The STM32 firmware was disassembled, and a Raspberry Pi Pico was turned into a passive
SPI sniffer ([sniffer.md](sniffer.md)). Together they revealed the complete register
interface: SPI mode 3 with a separate REGSEL line, 64 registers, waveform transfers through
the FPGA from the SPI flash (with scrambled bytes), an authentication handshake, the counter,
modulation and calibration registers. The stock firmware wrote all registers correctly –
there was nothing wrong on the STM32 side either.

**Decision:** write an own FPGA design that implements the original register interface, so
that the stock firmware and its user interface can stay unchanged.

## Building the replacement

| Version | Step |
|---|---|
| v0.1 | CH1 sine with the correct frequency; frequency sweep works (it runs in the firmware) |
| v0.2 | flash controller, waveform transfer into the wave RAM, single-byte flash reads |
| v0.3 | waveform modes (square with duty, trapezoid), MCP4822 for amplitude and offset |
| v0.5–v0.6 | range relays decoded (reg 0x05), offset DAC gain 2×, CMOS/pulse unipolar |
| – | **USB-Blaster workflow:** programming the flash through the AS header with a `.pof` built from a complete 2 MB image – a huge time saver compared to an external SPI programmer |
| v0.7 | CH2 (pins provided after tracing the board); the MCP4822 outputs are swapped on CH2 |
| v0.7b/c | CH2 showed random **spikes on steep edges**. Weaker data drivers did not help; a separate, phase-shifted PLL output for the CH2 DAC clock reduced them |
| v0.8 | frequency counter – worked at the first attempt. Switching AC/DC in the menu revealed that "DC" simply selects the Trig IN input (there is no coupling switch) |
| v0.8 | the counter showed 40 MHz for a 60 MHz output: an **alias** – the DDS ran at 100 MSPS |
| v0.9 | **125 MHz DDS** (the DAC-1412 maximum) with pipelined paths; with the CH2 DAC clock shifted by 6 ns the CH2 spikes were gone |
| v0.10 | **edge interpolation** for square waves: jitter from about 8 ns to about 0.7 ns; channel phase verified |
| v0.11 | removed the general register read-back (the firmware reads only 7 registers): logic usage 92 % → 60 % |
| v0.12 | modulation: AM, FM, PM, FSK, ASK, PSK with CH2 as source |
| v0.13 | burst and external sources (Counter input, Trig IN, MANU) |
| v0.13b | FM drifted against the CH2 trigger: the modulation signal was centred on 8192 instead of 8191.5 – a tiny DC offset became a carrier frequency error |
| v0.13c | MANU produced an endless burst. A sniffer capture showed that the unit runs **firmware 1.8.0**, which first writes burst count 0 when MANU is selected; count 0 now means "silent" |
| v0.13d | a register comparison 1.4.2 ↔ 1.8.0 found the start-up poll on register 0x3A: returning the expected ID removed a 4–5 s delay at every power-on |
| v0.14 | **VCO-IN**: the STM32 samples the input itself and streams 16-bit frames without an address. The SPI bit counters had never been reset between frames – one such frame would have shifted every later write. Fixed and simulated with the complete top level |
| v0.15 | TTL outputs Port A–D (a first pin mix-up showed up as "Port D stuck high") |
| v0.15c/v0.16 | Sync OUT and the **uplink** (master/slave) as described in the user manual |
| v0.17 | **Adj-Pulse** with a fixed pulse width in 4 ns steps (48-bit threshold instead of the 17-bit duty) |
| v0.18 | **frequency calibration**: the DDS constant is derived from the reference registers, so the hidden calibration menu works for the generator and the counter |

Finally all 144 FPGA pins were mapped from high-resolution photos of the two-layer board:
the 25 unused I/Os are not connected, so nothing in the signal path is left uncontrolled.

## Lessons learned

* **Measure the measurement.** A bad cable produced 1 V of "overshoot" on CH2; a 1× probe
  turned a square clock into a sine. Several wrong conclusions were avoided only by
  re-measuring.
* **A sniffer pays for itself.** Static analysis of the firmware was right most of the time,
  but the decisive details (firmware version, MANU count 0, the meaning of bits 8/7) came
  from captures – a filtered sniffer mode answered a question in minutes.
* **Know which firmware runs on the device.** Two versions were analysed in parallel; some
  behaviour existed only in 1.8.0.
* **Simulate what you cannot easily observe.** Burst counting at 60 MHz, the SPI framing of
  VCO-IN and the calibration division were verified in simulation before they were flashed.
* **Keep the build reproducible.** Every version was built from a clean compile with a
  verified `.pof`; the English source of this repository produces a bitstream bit-identical
  to the tested v0.18.

## Why the stock bitstream did not work

This was never proven. What is known:

* **Ruled out:** the hardware (this design uses the TCXO, the PLL at 250 MHz in a test, all
  I/O, both DACs, the MCP4822s, the amplifiers and the relays), the PLL configuration
  (bit-identical to a working test), the register traffic (correct with 1.4.2 and 1.8.0)
  and the flash content (identical to a reference dump after a repair of an interrupted
  waveform write).
* **Also ruled out since the release: the bitstream itself and the firmware.** A user
  reported the identical stock bitstream on an FY6900-60M with **FPGA board V1.9** and
  front panel V1.9, where it works with both firmware 1.4.2 and 1.8.0
  ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)). So the image is a working
  FeelTech design, and the ID check of firmware 1.8.0 (it polls register 0x3A for 0xFB69,
  this bitstream returns 0x10) only costs the 4–5 s start-up delay – it does not stop the
  generator.
* **Symptom:** the stock design ran (it switched relays, reacted to register writes and
  showed the first sample of the selected waveform), but its DDS never started and the DAC
  clock stayed off – an internal start condition was not met.

Two explanations remain:

1. **Most likely: the bitstream was made for older boards and does not work on board
   V2.1.** On the V2.1 test unit it drives the relays and the DAC data lines on the same
   pins as this project, so the outputs match – but something the design waits for before
   it starts the DDS is different on V2.1, for example an input that is wired differently,
   a changed component or a timing detail. FeelTech probably ships V2.1 boards with a newer
   bitstream – that would be the one reporting the FPGA ID 0xFB69 that firmware 1.8.0 asks
   for (1.8.0 also uses partly different waveform flash areas). No dump available here
   contains it. The test unit arrived with a dead STM32; an earlier repair attempt may have
   put the older, publicly circulating image into its flash – which would also explain why
   all available dumps contain the same bitstream.
2. **Less likely: a pairing check between STM32 and FPGA** (the challenge/response handshake).
   A bitstream that is identical in every unit cannot verify a response derived from each
   STM32's unique ID unless per-unit pairing data were stored in the flash, and none was
   found.

A flash dump of a **working** FY6900 with **FPGA board V2.1** would settle it: its
bitstream would most likely be the newer one, and comparing the two designs would show what
changed – see [known-bitstreams.md](known-bitstreams.md).

## The project in numbers

The whole project – from the first look at the flash dump to the published repository – ran
as one long session with the AI coding assistant Claude Code. The assistant analysed the
firmware, wrote the FPGA design, the testbenches, the tools, the sniffer and this
documentation. All work on the real unit was done by hand at the bench: measuring, tracing
the board, flashing, sniffing and testing every version.

| | |
|---|---|
| Duration | 4–9 November 2026, 13 sittings, about **26 active hours** |
| … of which the assistant was working | about 5.6 hours; the rest was measuring, flashing, testing and reading |
| Conversation | 257 messages from the developer, 1,102 assistant steps, 975 tool calls |
| Test bitstreams | **30** (v0.2–v0.18 including variants) from 58 Quartus compiles |
| Simulation runs | 25 |
| Sniffer firmware builds | 43 |
| Python script runs (analysis, flash images, models) | about 340 |
| Tokens | about 500 million re-read, 7.5 million stored, 1.5 million written |
| Largest conversation | about 970,000 tokens – it had to be summarised three times |
| Result (v0.18) | 1,260 lines of Verilog, 464 lines of testbenches, 382 lines of Python, 312 lines of sniffer code, about 12,600 words of documentation |

Writing was the small part: before every step the assistant re-reads the whole
conversation so far. Weighted by cost (re-reading about 0.1×, storing 2×, writing 5×), the
project came to about 72 million "effective" tokens. About half of that was the assistant
re-reading its own earlier reasoning, a quarter the output of builds, simulations and
scripts, and a sixth its fixed instructions. The times were estimated from the message
timestamps (pauses of more than 45 minutes count as breaks), so bench work between two
messages counts as active time.
