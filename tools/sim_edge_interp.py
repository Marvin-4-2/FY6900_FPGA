#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
"""
sim_edge_interp.py - bit-accurate model of the square-wave edge interpolation in dds_ch.

A DDS square wave at 125 MSPS has edges that can only sit on sample positions, so the edge
position jitters by up to one sample period (8 ns) from period to period. The FPGA outputs
the fraction of the sample interval during which the ideal signal was high for the sample
that contains an edge; the analog reconstruction filter turns this into an edge at the
correct sub-sample position.

This script models the FPGA arithmetic (48-bit phase, 13-bit normalised reciprocal, 14-bit
fraction) and estimates the peak-to-peak edge jitter after an ideal 50 MHz low-pass filter,
with and without interpolation.

Usage: python sim_edge_interp.py      (needs numpy)
"""
import numpy as np

FCLK = 125e6                  # DDS sample rate
K = 0x36F9BFB3B               # frequency constant: inc = (F[0.1 Hz] * K) >> 16
M48 = (1 << 48) - 1


def rec_of(inc):
    """Normalise inc (s = leading zeros) and compute rec = 2^26 / inc_norm[47:35] like the FPGA."""
    t, s = inc, 0
    while not (t >> 47) & 1 and s < 47 and t:
        t <<= 1
        s += 1
    div = (t >> 35) & 0x1FFF
    return s, (0 if div == 0 else (1 << 26) // div)


def run(f_hz, duty_pct, n, interp=True):
    """Generate n samples (0 / 16383 or the interpolated fraction) of a square wave."""
    inc = ((int(f_hz * 10) * K) >> 16) & M48
    s, rec = rec_of(inc)
    duty = int(duty_pct / 100 * (1 << 17))
    D = duty << 31                         # threshold as 48-bit phase
    ph, out = 0, []
    prev = 0
    for _ in range(n):
        nxt = ph + inc
        wrap = nxt > M48
        prev, ph = ph, nxt & M48
        hi_now = (ph >> 31) < duty
        hi_prev = (prev >> 31) < duty
        if interp and wrap and hi_now and not hi_prev:          # rising edge: x = phase after the edge
            x = ph
        elif interp and (not wrap) and hi_prev and not hi_now:  # falling edge: x = threshold - previous phase
            x = (D - prev) & M48
        else:
            out.append(16383 if hi_now else 0)
            continue
        x13 = ((x << 13) >> (60 - s - 12)) & 0x1FFF             # = (x << s)[47:35]
        p = x13 * rec
        frac = 16383 if (p >> 26) else (p >> 12) & 0x3FFF
        out.append(frac)
    return np.array(out, float)


def edge_jitter(sig, f_hz):
    """Peak-to-peak deviation of the rising zero crossings from an ideal period grid after an
    ideal 50 MHz low-pass (FFT brick-wall filter, 16x oversampled)."""
    up = 16
    X = np.fft.rfft(sig - sig.mean())
    fr = np.fft.rfftfreq(len(sig), 1 / FCLK)
    X[fr > 50e6] = 0
    y = np.fft.irfft(X, len(sig) * up) * up
    t = np.arange(len(y)) / (FCLK * up)
    idx = np.where((y[:-1] < 0) & (y[1:] >= 0))[0]
    tc = t[idx] + (0 - y[idx]) / (y[idx + 1] - y[idx]) / (FCLK * up)
    tc = tc[5:-5]
    k = np.round((tc - tc[0]) * f_hz)
    err = tc - tc[0] - k / f_hz
    err -= err.mean()
    return (err.max() - err.min()) * 1e9


if __name__ == "__main__":
    for f, d in [(1e6 + 123.4, 50), (3.3e6, 30), (7.77e6, 50), (12.345e6, 70)]:
        a = run(f, d, 1 << 15, False)
        b = run(f, d, 1 << 15, True)
        print("f = %.4g Hz, duty %d %%: jitter p-p without %.2f ns, with interpolation %.2f ns"
              % (f, d, edge_jitter(a, f), edge_jitter(b, f)))
