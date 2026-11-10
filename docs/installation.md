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

* An FY6900 with **FPGA board V2.1** (printed on the board; V1.9 very likely works too) – see
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

The tool shows the SHA-256 of the bitstream area. Continue only if it reports
**"FeelTech stock bitstream (FY6900 60 MHz, FPGA boards V1.9 and V2.1 …)"** or a bitstream of this
project. An unknown bitstream means your board may have a different pin assignment – see
[Compatibility](#compatibility) and please report it.

## 4. Patch your dump

```
python tools/fy6900_flash.py patch backup.bin release/fy6900_fpga_v0.18.rbf patched.bin
```

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

Patch your backup (or the already patched image – the tool accepts bitstreams of this
project) with the new `.rbf`, create the `.pof` and program it.

## Compatibility

Tested on one unit: **FY6900 60 MHz, FPGA board V2.1, front panel board V2.2, STM32 firmware
1.8.0** (1.4.2 also writes the same registers). Several FY6900 flash dumps from different
sources contain the identical stock bitstream, which strongly suggests the same pin
assignment – among them a unit with **FPGA board V1.9** and front panel V1.9, where the stock
bitstream works ([#2](https://github.com/Marvin-4-2/FY6900_FPGA/issues/2)). This project's
bitstream has not been tested on V1.9 yet; if you try it, please report the result. The
`patch` command refuses dumps with an unknown bitstream; `--force`
overrides this – use it only after checking your board against [pinout.csv](pinout.csv).
A wrong pin assignment can make the FPGA drive against other outputs on the board.

Known bitstreams are listed in [known-bitstreams.md](known-bitstreams.md).
