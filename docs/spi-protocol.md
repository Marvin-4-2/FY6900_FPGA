# STM32 ↔ FPGA SPI protocol

The STM32F103 on the front panel board talks to the FPGA over a 5-wire SPI link through the
cable between the two boards. This page describes the transport; the meaning of the
registers is in [registers.md](registers.md).

## Physical layer

| Signal | STM32 pin | FPGA pin | Notes |
|---|---|---|---|
| SCK | PB13 | 32 | SPI2, 18 MHz (APB1 36 MHz / 2) |
| MOSI | PB15 | 30 | STM32 → FPGA |
| MISO | PB14 | 31 | FPGA → STM32 |
| CS | PB12 | 33 | software chip select (GPIO), active low |
| REGSEL | PB11 | 34 | GPIO: low = address phase, high = data phase |

SPI settings of the firmware: master, **mode 3** (CPOL = 1, CPHA = 1), **16-bit words**,
MSB first. The FPGA samples MOSI on the rising SCK edge and shifts MISO out on the falling
edge.

## Transactions

All transactions are complete within one CS frame (CS low … CS high).

### Write

```
REGSEL = 0, CS = 0
  16 bit  register address (0x00..0x3F)
REGSEL = 1
  16 bit  data[31:16]
  16 bit  data[15:0]
CS = 1
```

There is no read/write flag in the address. The FPGA commits a write when an address *and*
a 32-bit data word arrived in the same frame.

### Read

```
REGSEL = 0, CS = 0
  16 bit  register address
CS = 1                       (short pause)
REGSEL = 1, CS = 0
  16 bit  read data[31:16] on MISO (MOSI = 0)
  16 bit  read data[15:0]
CS = 1
```

Read and write are distinguished by whether data follows the address in the same frame.
The FPGA has several microseconds between the address frame and the data frame to prepare
the read word.

### Read again

```
REGSEL = 1 (unchanged), CS = 0
  32 bit  read data
CS = 1
```

Re-reads the last addressed register; the firmware uses it for busy polling during flash
transfers.

### VCO-IN frames

When AM, FM or PM use the external source **Ext.(VCO-IN)**, the firmware samples the VCO-IN
socket with the STM32 ADC and sends every new value in a short frame:

```
REGSEL = 1 (stays high), CS = 0
  16 bit  ADC value × 1.1, limited to 4095 (0x800 = no modulation)
CS = 1
```

There is no address phase and only 16 data bits. An FPGA that counts bits across frames
would be shifted by 16 bits after the first such frame and misinterpret every following
write. This design therefore resets its bit counters while CS is high and treats a frame
with exactly 16 data bits and no address as a VCO-IN sample (stored in register 0x2D).

## Special cases

* Register 0x1B (authentication challenge): the firmware's read routine reorders the lower
  byte of the value read (`(x & 0x0F) | ((x >> 2) & 0x30) | ((x & 0x30) << 2)`).
* Register 0x0C (flash byte): the original FPGA returns the flash byte with a fixed bit
  permutation that the firmware undoes (see [registers.md](registers.md#waveform-transfer-and-flash-access)).
* The original FPGA drives 0x000000AF on MISO when idle. This design drives the last read
  word; the firmware never relies on the idle value.

## Firmware reference (STM32 flash addresses)

| Function | 1.4.2 | 1.8.0 |
|---|---|---|
| FPGA_Write(value, reg) | 0x08009384 | 0x08009538 |
| FPGA_Read(reg) | 0x0800930C | 0x080094C0 |
| FPGA_ReadAgain() | 0x0800935C | 0x08009510 |
| SPI2 16-bit transfer | 0x0800B02C | 0x0800B2AC |
