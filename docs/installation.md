# Installation

This replaces the FPGA bitstream in the generator's SPI flash. The STM32 firmware is not
touched. The procedure is reversible as long as you keep the backup of your flash.

> **Warning.** You open a mains-powered device, and the flash is backed up and programmed
> while the unit is powered. **Unplug the mains cable and power the unit from the USB port on
> the back with a USB power supply** – that is enough for backing up and programming the
> flash, and there is no mains voltage inside the open case. Work at your own risk and only
> continue if you can restore the original flash (step 2). This project is not affiliated
> with FeelTech/FeelElec.

> **Tip:** a USB power bank instead of a USB power supply keeps the unit completely
> isolated – no mains earth and no ground loop through the PC and the USB-Blaster.

## What you need

* An FY6900 with **FPGA board V2.1 or V1.9** (printed on the board) – see
  [Compatibility](#compatibility)
* An Intel/Altera **USB-Blaster** (clones work) with the 10-pin cable
* **Intel Quartus Prime Programmer** with Cyclone IV support – either the stand-alone
  "Quartus Prime Programmer and Tools" or a full Quartus Prime Lite installation. It includes
  `quartus_cpf`, which the tool below needs.
* **Python 3.7** or newer
* A **USB power supply** (5 V) or a USB power bank to power the open unit through its rear
  USB port
* Optionally a 3.3 V SPI flash programmer (e.g. CH341A) for the backup

## 1. Open the unit and find the programming header

The 10-pin Active Serial header is on the FPGA board next to the SPI flash (pinout in
[hardware.md](hardware.md#programming-header-active-serial-10-pins)). The USB-Blaster cable
plugs in directly; pin 1 is marked on the board.

**Note the revision printed on the FPGA board** (e.g. "V2.1"). It decides whether this
project fits your unit (see [Compatibility](#compatibility)), and the patch tool asks for it
in step 4.

## 2. Back up the flash

The flash contains the FPGA bitstream **and your waveforms**. Keep the backup – it is the
only way back to the original state.

**Option A – SPI flash programmer:**
1. Power the unit (USB power supply on the rear USB port, mains cable unplugged) and pull
   **nCONFIG (header pin 5) to GND** through about 100 Ω.
   This holds the FPGA in reset and releases the flash lines.
2. Connect a **3.3 V** SPI programmer to the header: CLK → pin 1 (DCLK), MOSI → pin 9 (ASDO),
   MISO → pin 7 (DATA0), CS → pin 8 (nCS), GND → pin 2/10. Do **not** connect VCC while the
   unit is powered. (Alternatively use a SOIC-8 clip directly on the W25Q16 with the unit
   unpowered and the programmer supplying 3.3 V.)
3. Read the W25Q16 (2 MB) twice and compare both reads. Then release nCONFIG.

**Option B – USB-Blaster (not yet tested on a real unit):**
1. In the Quartus Programmer select the USB-Blaster, mode **Active Serial Programming**,
   add the device EPCS16 and tick **Examine**. Start and save the result as a `.pof`.
2. Convert it: `python tools/fy6900_flash.py unpof backup.pof backup.bin`

## 3. Check the dump

```
python tools/fy6900_flash.py info backup.bin
```

The tool shows the SHA-256 of the bitstream area and identifies it. This tells you **what is
in your flash, not which board you have** – the flash can hold any image (the test unit
carried the known stock bitstream although that bitstream never worked on it).

* **"FeelTech stock bitstream …"** or a bitstream of this project: as expected.
* **Unknown bitstream:** not a problem by itself – a working unit with FPGA board V2.1
  probably has a newer stock bitstream. Please report it
  ([known-bitstreams.md](known-bitstreams.md)).
* **"does not contain a Cyclone IV bitstream":** the read is empty or bad. Read the flash
  again and compare two reads before you continue.

## 4. Patch your dump

Pass the revision printed on your FPGA board with `--board`:

```
python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.18.rbf patched.bin --board V2.1
```

* **V2.1 or V1.9:** tested, the tool patches.
* **Any other revision:** the tool refuses. Compare your board with [pinout.csv](pinout.csv)
  first; `--force` patches anyway.

Only the bitstream area (0x000000–0x059FFF) is replaced; your waveforms are kept.

## 5. Create the programming file

```
python tools/fy6900_flash.py pof patched.bin patched.pof
```

The tool finds `quartus_cpf` through `QUARTUS_ROOTDIR` or the PATH (or pass `--cpf <path>`).
It converts the `.pof` back and compares it with the image; it must report
"read-back check: ok".

## 6. Program

1. Power the unit (USB power supply on the rear USB port, mains cable unplugged) and plug the
   USB-Blaster cable onto the header.
2. Quartus Programmer → **Hardware Setup**: USB-Blaster; **Mode: Active Serial Programming**.
3. **Add File** `patched.pof` (device EPCS16), tick **Program/Configure** and **Verify**.
4. **Start**. The USB-Blaster handles nCONFIG itself; do not pull it manually.
5. Disconnect the USB power supply and the USB-Blaster, close the case and power the unit
   normally.

The USB-Blaster does not power the board – the unit must be powered while programming.

## 7. Check

* The generator starts normally (with firmware 1.8.0 a few seconds faster than before –
  the original bitstream made the firmware wait for an ID it never got).
* CH1 and CH2 output a sine at the set frequency, amplitude and offset follow the settings,
  the range relays click when you cross about 350 mV and 6 Vpp.
* Optionally run through the [test list](../README.md#status).

## Restoring the original

```
python tools/fy6900_flash.py pof backup.bin backup.pof
```

and program `backup.pof` as in step 6.

## Updating to a newer release

Patch your backup (or the already patched image) with the new `.rbf` and the same
`--board` revision, create the `.pof` and program it.

## Compatibility

What matters is the **FPGA board revision**. A wrong pin assignment can make the FPGA drive
against other outputs on the board.

| FPGA board | Status |
|---|---|
| **V2.1** | **tested** on one unit: FY6900 60 MHz, front panel board V2.2, STM32 firmware 1.8.0 (1.4.2 also writes the same registers) |
| **V1.9** | **tested** on a second unit: FY6900-60M, front panel board V1.9 ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)) |
| other | unknown – compare with [pinout.csv](pinout.csv) before you use `--force`, and please report the result |

Both boards share the pin assignment of the stock bitstream: it is identical on both, works
on V1.9, and on the V2.1 unit it drove the relays, the DAC data lines and the MCP4822s on
exactly the pins this project uses – only its DDS never started there.

The bitstream in your flash dump is **not** proof of compatibility: the flash can contain an
image from another unit – the V2.1 test unit carried the stock bitstream although it never
worked on it. `fy6900_flash.py` identifies the bitstream only as a second check (and to
catch bad reads); known bitstreams are listed in [known-bitstreams.md](known-bitstreams.md).
