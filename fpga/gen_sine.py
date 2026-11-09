#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
"""
Generate sine8192.hex - the power-on content of both wave RAMs.

The table holds one sine period with 8192 samples of 14 bit (0..16383), centred on 8191.5
so that the table is exactly symmetric (mean value 8191.5). The stock firmware loads the
selected waveform from the SPI flash right after power-on, so this table is only visible
for a moment, but it gives a sensible output before the first waveform transfer.

Usage:
    python gen_sine.py            # writes sine8192.hex next to this script
"""
import math
import os

N = 8192            # samples per period (13-bit wave RAM address)
FULL = 16383        # 14-bit full scale


def main():
    half = FULL / 2.0
    lines = []
    for i in range(N):
        v = int(round(half + half * math.sin(2.0 * math.pi * i / N)))
        v = max(0, min(FULL, v))
        lines.append("%04x" % v)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sine8192.hex")
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("written:", path)


if __name__ == "__main__":
    main()
