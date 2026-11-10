#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
"""
fy6900_flash.py - prepare the W25Q16 SPI flash image of a FeelTech FY6900 for this project.

The FPGA of the FY6900 configures itself from a 2 MB W25Q16 SPI flash (Active Serial,
EPCS16 compatible). The first 0x5A000 bytes hold the FPGA bitstream, the rest holds the
waveform tables that the STM32 firmware loads through the FPGA. This tool replaces only the
bitstream area and keeps everything else from YOUR OWN flash dump.

Sub-commands
  info    <dump.bin>                         show size and identify the bitstream (SHA-256)
  patch   <dump.bin> <bitstream.rbf> <out.bin> [--force]
                                             insert the bitstream (.rbf) into a copy of the dump
  pof     <image.bin> <out.pof> [--cpf PATH] convert a 2 MB image into a .pof for the
                                             Quartus Programmer (USB-Blaster, Active Serial),
                                             including an automatic read-back check
  unpof   <in.pof> <out.bin> [--cpf PATH]    convert a .pof back into a 2 MB binary image
                                             (e.g. to inspect or archive a .pof)

Safety
  "patch" refuses to work on a dump whose bitstream area is unknown. A known stock bitstream
  means the board has the pin assignment this project was made for. Use --force only after
  checking the pin assignment of your board yourself (docs/pinout.csv) - a wrong pin
  assignment can make the FPGA drive against other outputs on the board.

Requirements: Python 3.7+, for pof/unpof the quartus_cpf tool of Intel Quartus Prime
(any edition with Cyclone IV support). It is searched in --cpf, $QUARTUS_ROOTDIR/bin64,
$QUARTUS_ROOTDIR/bin and the PATH.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

FLASH_SIZE     = 0x200000   # W25Q16: 2 MB
BITSTREAM_AREA = 0x5A000    # area occupied by the FPGA bitstream (the stock one ends at 0x59D50)
SYNC_FLASH     = 0x56       # first non-0xFF byte of a Cyclone IV bitstream in flash byte order

# SHA-256 of flash[0:0x5A000] -> description. Please report other values together with the
# board revisions of your unit (see README, "Contributing").
KNOWN_BITSTREAMS = {
    "89632919deee57d3639dc64ba47d3ba80cc34e3998c8f58d9baca5b7057428e5":
        ("stock", "FeelTech stock bitstream (FY6900 60 MHz, FPGA boards V1.9 and V2.1; ID register 0x3A = 0x10)"),
    # bitstreams of this project (re-patching an already patched unit is allowed)
    "f15cbb2f2eaa7d125e04360a7c7ef1715425b635f97692310a4733ebb36f2a4f":
        ("project", "FY6900_FPGA v0.18 (this project)"),
}


def rev8(b):
    """Reverse the bit order of one byte (the FPGA reads the flash LSB first)."""
    r = 0
    for i in range(8):
        r = (r << 1) | ((b >> i) & 1)
    return r


REV = bytes(rev8(i) for i in range(256))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_image(path):
    data = open(path, "rb").read()
    if len(data) != FLASH_SIZE:
        sys.exit("error: %s is %d bytes, a W25Q16 image must be exactly %d bytes (2 MB)"
                 % (path, len(data), FLASH_SIZE))
    return data


def identify(data):
    """Return (sha256, kind, description) of the bitstream area."""
    h = sha256(data[:BITSTREAM_AREA])
    kind, desc = KNOWN_BITSTREAMS.get(h, ("unknown", "unknown bitstream"))
    return h, kind, desc


def rbf_to_flash(rbf):
    """Convert a Quartus .rbf into flash byte order (bit-reversed) and check the sync byte."""
    if len(rbf) > BITSTREAM_AREA:
        sys.exit("error: bitstream is %d bytes, the bitstream area holds only %d" % (len(rbf), BITSTREAM_AREA))
    flash = rbf.translate(REV)
    i = 0
    while i < len(flash) and flash[i] == 0xFF:
        i += 1
    if i >= len(flash) or flash[i] != SYNC_FLASH:
        sys.exit("error: this does not look like a Cyclone IV .rbf (sync byte not found)")
    return flash


# ------------------------------------------------------------------------------------
# info / patch
# ------------------------------------------------------------------------------------
def cmd_info(args):
    data = load_image(args.dump)
    h, kind, desc = identify(data)
    end = len(data[:BITSTREAM_AREA].rstrip(b"\xff"))
    print("file:            %s" % args.dump)
    print("size:            %d bytes (ok)" % len(data))
    print("bitstream bytes: 0x000000 .. 0x%06x" % end)
    print("bitstream SHA-256 (flash 0x000000..0x%06x): %s" % (BITSTREAM_AREA, h))
    print("identified as:   %s" % desc)
    if kind == "unknown":
        print("\nThis bitstream is not in the list of known bitstreams. Please report the SHA-256")
        print("together with the board revisions of your unit (see README, Contributing).")


def cmd_patch(args):
    dump = load_image(args.dump)
    h, kind, desc = identify(dump)
    print("dump bitstream:  %s" % desc)
    if kind == "unknown" and not args.force:
        sys.exit("\nrefusing to patch: the bitstream in this dump is unknown (SHA-256 %s).\n"
                 "Check the pin assignment of your board against docs/pinout.csv first,\n"
                 "then run again with --force." % h)
    if kind == "unknown":
        print("warning: unknown bitstream, continuing because of --force")
    rbf = open(args.rbf, "rb").read()
    flash = rbf_to_flash(rbf)
    img = bytearray(dump)
    img[0:BITSTREAM_AREA] = b"\xff" * BITSTREAM_AREA
    img[0:len(flash)] = flash
    with open(args.out, "wb") as f:
        f.write(img)
    print("bitstream:       %s (%d bytes)" % (args.rbf, len(rbf)))
    print("written:         %s" % args.out)
    print("new bitstream area SHA-256: %s" % sha256(bytes(img[:BITSTREAM_AREA])))
    print("data above 0x%06x taken unchanged from the dump" % BITSTREAM_AREA)


# ------------------------------------------------------------------------------------
# pof / unpof (Intel HEX <-> quartus_cpf)
# ------------------------------------------------------------------------------------
def find_cpf(explicit):
    cands = []
    if explicit:
        cands.append(explicit)
    root = os.environ.get("QUARTUS_ROOTDIR")
    for sub in ("bin64", "bin"):
        if root:
            cands.append(os.path.join(root, sub, "quartus_cpf.exe"))
            cands.append(os.path.join(root, sub, "quartus_cpf"))
    for name in ("quartus_cpf.exe", "quartus_cpf"):
        p = shutil.which(name)
        if p:
            cands.append(p)
    for c in cands:
        if c and os.path.isfile(c):
            return c
    sys.exit("error: quartus_cpf not found - pass --cpf <path to quartus_cpf> or set QUARTUS_ROOTDIR")


def write_ihex(data, path):
    """Write data as Intel HEX with extended linear address records."""
    with open(path, "w") as f:
        for base in range(0, len(data), 0x10000):
            hi = base >> 16
            rec = [0x02, 0x00, 0x00, 0x04, hi >> 8, hi & 0xFF]
            f.write(":%s%02X\n" % ("".join("%02X" % b for b in rec), (-sum(rec)) & 0xFF))
            for off in range(0, min(0x10000, len(data) - base), 16):
                chunk = data[base + off: base + off + 16]
                rec = [len(chunk), off >> 8, off & 0xFF, 0x00] + list(chunk)
                f.write(":%s%02X\n" % ("".join("%02X" % b for b in rec), (-sum(rec)) & 0xFF))
        f.write(":00000001FF\n")


def read_ihex(path, size):
    out = bytearray(b"\xff" * size)
    upper = 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(":"):
            continue
        b = bytes.fromhex(line[1:])
        n, addr, typ = b[0], (b[1] << 8) | b[2], b[3]
        if typ == 0x04:
            upper = (b[4] << 8) | b[5]
        elif typ == 0x00:
            a = (upper << 16) | addr
            if a + n <= size:
                out[a:a + n] = b[4:4 + n]
        elif typ == 0x01:
            break
    return bytes(out)


def pof_to_image(cpf, pof_path, work):
    """Convert a .pof to a flash image. quartus_cpf writes the hexout in RBF bit order, i.e.
    every byte bit-reversed relative to the flash content."""
    back = os.path.join(work, "back.hexout")
    r = subprocess.run([cpf, "-c", pof_path, back], capture_output=True, text=True, cwd=work)
    if not os.path.exists(back):
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit("error: quartus_cpf could not convert %s" % pof_path)
    return read_ihex(back, FLASH_SIZE).translate(REV)


def cmd_pof(args):
    cpf = find_cpf(args.cpf)
    img_path, pof_path = os.path.abspath(args.image), os.path.abspath(args.pof)
    data = load_image(img_path)
    work = tempfile.mkdtemp(prefix="fy6900_pof_")
    hexp = os.path.join(work, "data.hex").replace("\\", "/")
    write_ihex(data, hexp)
    # Conversion setup for quartus_cpf: EPCS16, the hex file is placed at absolute address 0
    # (n_pages = 0: no Quartus page layout, the image already contains everything)
    cof = os.path.join(work, "conv.cof")
    with open(cof, "w") as f:
        f.write("""<?xml version="1.0" encoding="US-ASCII" standalone="yes"?>
<cof>
\t<eprom_name>EPCS16</eprom_name>
\t<output_filename>{out}</output_filename>
\t<n_pages>0</n_pages>
\t<width>1</width>
\t<mode>7</mode>
\t<hex_block>
\t\t<hex_filename>{hexp}</hex_filename>
\t\t<hex_addressing>absolute</hex_addressing>
\t\t<hex_offset>0</hex_offset>
\t\t<hex_little_endian>0</hex_little_endian>
\t</hex_block>
\t<version>10</version>
\t<create_cvp_file>0</create_cvp_file>
\t<create_hps_iocsr>0</create_hps_iocsr>
\t<auto_create_rpd>0</auto_create_rpd>
\t<rpd_little_endian>1</rpd_little_endian>
\t<options>
\t\t<map_file>1</map_file>
\t</options>
</cof>
""".format(out=pof_path.replace(os.sep, "/"), hexp=hexp))
    if os.path.exists(pof_path):
        os.remove(pof_path)
    r = subprocess.run([cpf, "-c", cof], capture_output=True, text=True, cwd=work)
    if not os.path.exists(pof_path):
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit("error: POF generation failed")
    # read-back check: the .pof must contain exactly the image
    got = pof_to_image(cpf, pof_path, work)
    diff = sum(1 for a, b in zip(got, data) if a != b)
    shutil.rmtree(work, ignore_errors=True)
    print("written:         %s" % pof_path)
    if diff:
        os.remove(pof_path)
        sys.exit("error: read-back check failed (%d bytes differ) - .pof deleted" % diff)
    print("read-back check: ok (POF content identical to the image)")


def cmd_unpof(args):
    cpf = find_cpf(args.cpf)
    work = tempfile.mkdtemp(prefix="fy6900_unpof_")
    data = pof_to_image(cpf, os.path.abspath(args.pof), work)
    shutil.rmtree(work, ignore_errors=True)
    with open(args.out, "wb") as f:
        f.write(data)
    h, kind, desc = identify(data)
    print("written:         %s (%d bytes)" % (args.out, len(data)))
    print("bitstream:       %s" % desc)


def main():
    ap = argparse.ArgumentParser(description="Prepare FY6900 W25Q16 flash images (see docs/installation.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info", help="identify the bitstream of a 2 MB flash dump")
    p.add_argument("dump")
    p.set_defaults(func=cmd_info)
    p = sub.add_parser("patch", help="insert a bitstream (.rbf) into a copy of your flash dump")
    p.add_argument("dump"); p.add_argument("rbf"); p.add_argument("out")
    p.add_argument("--force", action="store_true", help="also patch dumps with an unknown bitstream")
    p.set_defaults(func=cmd_patch)
    p = sub.add_parser("pof", help="convert a 2 MB image into a .pof (USB-Blaster, Active Serial)")
    p.add_argument("image"); p.add_argument("pof")
    p.add_argument("--cpf", help="path to quartus_cpf")
    p.set_defaults(func=cmd_pof)
    p = sub.add_parser("unpof", help="convert a .pof back into a 2 MB image")
    p.add_argument("pof"); p.add_argument("out")
    p.add_argument("--cpf", help="path to quartus_cpf")
    p.set_defaults(func=cmd_unpof)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
