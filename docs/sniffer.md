# SPI sniffer (Raspberry Pi Pico)

[`sniffer/`](../sniffer) contains a passive logic sniffer for the STM32 ↔ FPGA SPI bus. It was
used to reconstruct and verify the register interface and is useful for anyone who wants to
investigate other firmware versions or features.

## Hardware

A Raspberry Pi Pico (RP2040). All Pico pins are inputs; connect GND.

| Pico | Signal | STM32 pin | FPGA pin |
|---|---|---|---|
| GP2 | SCK | PB13 | 32 |
| GP3 | MOSI | PB15 | 30 |
| GP4 | MISO | PB14 | 31 |
| GP5 | REGSEL | PB11 | 34 |
| GP6 | CS | PB12 | 33 |
| GND | GND | | |

The signals can be picked up on the cable between the front panel and the FPGA board. A
small adapter board between the cable and the connector is more convenient than soldering
wires to the connector.

## Build and flash

```
cd sniffer
pio run -t upload          # PlatformIO; or copy .pio/build/pico/firmware.uf2 in BOOTSEL mode
pio device monitor         # 115200 baud, any terminal program works
```

The PIO state machine samples MOSI, MISO, REGSEL and CS on every rising SCK edge at up to
the 18 MHz of the bus, a DMA channel writes the samples into a ring buffer and the main loop
decodes them.

## Output

```
W 07 = 000186a0           write: register 0x07 = 100000 (CH1 10 kHz)
R 1f -> 00000010          read
R+ 15 -> 00000000         read again (busy polling)
?  04  (write of 0 or read of 0)
FR 060000 -> 3c           flash byte read (sequence 17/0d/15/0c combined)
W 05 = 000001c0  (x50)    repeated lines are combined
```

A write of 0 cannot be distinguished from a read of 0 on the bus; it is printed as `?`.

## Modes

Press a key in the terminal:

| Key | Mode |
|---|---|
| `a` | all accesses (default) |
| `c` | changed writes only: a write is printed when its value differs from the last value written to that register; reads are suppressed – handy to see what a menu action changes |
| `f` | filter: changes of register 0x05 bits 8/7 and writes to register 0x00, with time stamps (the filter that identified bits 8/7 as the output enable bits) |

## Limitations

* The 16-bit VCO-IN frames (AM/FM/PM with Ext.(VCO-IN)) are not decoded and disturb the word
  alignment while they are being sent.
* If the USB output cannot keep up, the sniffer prints `OVERFLOW` and resynchronises.
