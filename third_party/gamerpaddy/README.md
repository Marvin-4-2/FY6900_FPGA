# updateFW.py – FY firmware update utility by gamerpaddy

`updateFW.py` is a small GUI tool by **gamerpaddy** that uploads a FeelTech front panel
firmware file (`.FYbi`) to the STM32 of the FY6900 through the USB port on the back of the
unit (CH340 USB-UART → STM32 UART). It was originally posted in the EEVblog forum topic
["FeelElec New Arrival FY-6900 Signal Generator"](https://www.eevblog.com/forum/testgear/re-feelelec-new-arrival-fy-6900-signal-generator/).

This tool brought the dead front panel of the test unit back to life, which is how this
project could start at all – see [history.md](../../docs/history.md#the-starting-point).

## Licence

Copyright gamerpaddy. Included **unchanged** (byte-identical, see `.gitattributes`) with the
permission of the author. The CERN-OHL-S licence of this project does **not** apply to this
file.

## Requirements

* Python 3 with Tkinter (part of the standard Windows and macOS installers)
* pyserial: `pip install pyserial`

## Usage

1. Connect the USB port on the back of the generator to the PC.
2. Start the tool: `python updateFW.py`
3. Select the COM port and 115200 baud. **Check Connection** asks the running firmware for
   its model and version.
4. **Browse** for the `.FYbi` file and press **Upload Firmware**. At the end the unit
   confirms and starts the new firmware.

The firmware files belong to FeelTech/FeelElec and are not part of this repository. The FPGA
design of this project was tested with front panel firmware **1.8.0** (see
[firmware-notes.md](../../docs/firmware-notes.md)).

> **Caution.** Only upload firmware for your model, and do not interrupt the upload – an
> interrupted or wrong update can leave the front panel without working firmware.

## Update protocol

As implemented by the script (115200 baud, ASCII commands terminated with `\n`):

| Step | PC sends | Unit answers |
|---|---|---|
| Prepare the file | – an ASCII header such as `FY6900__1.6>>` at the start and the last 4 bytes of the file are removed | |
| Start | `<PrSTM32_START` | `START` |
| For each 2048-byte block *n* | `<IAPSTM32_<size>_<n>_<sum>_` (size = bytes in this block, sum = 16-bit sum of the block bytes, decimal) | `WrStart` |
| | the raw block bytes | `WrEND` |
| Run | `<PrSTM32_DO` | `RUN` |
