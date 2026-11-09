# Building and simulation

## Building the bitstream

Requirements: Intel Quartus Prime Lite with Cyclone IV E device support. The project was
developed with Quartus Prime 25.1 Lite; older versions with Cyclone IV support should work.

```
cd fpga
quartus_sh --flow compile fy_fpga
```

Results: `fy_fpga.sof` and `fy_fpga.rbf` (raw binary, used by `tools/fy6900_flash.py`).
Check the timing summary (`fy_fpga.sta.rpt`): all slacks must be positive. The design uses
about 90 % of the logic, so changes may need pipelining to keep 125 MHz.

The compile prints thousands of warnings "truncated value with size 16 … sine8192.hex" –
Quartus reads the 4-digit hex values as 16 bits; they are harmless.

`gen_sine.py` regenerates `sine8192.hex`.

## Testbenches

[`fpga/sim/`](../fpga/sim) contains self-checking testbenches. Each prints `PASS`/`FAIL`
per check and a final `RESULT:` line.

| Testbench | Scope |
|---|---|
| `tb_burst.v` | burst with all trigger sources (also at 50/60 MHz), retrigger, FSK keying (external, MANU) |
| `tb_manu.v` | MANU register sequence of firmware 1.8.0 (count 0 while armed, OK key, count reduced during a burst) |
| `tb_fm.v` | FM without mean frequency offset, PM scale |
| `tb_ttl.v` | position of the TTL edges relative to the DAC output, duty cycle, channel off |
| `tb_adjp.v` | Adj-Pulse widths (100 µs at 1 and 2 kHz, 4 ns steps, 100 ns at 10 Hz, limits) |
| `tb_spi.v` | complete top level: SPI writes/reads/VCO-IN frames as sent by firmware 1.8.0, ID registers, uplink master/slave, frequency calibration |

Run them with Questa (the Intel FPGA Starter edition installed with Quartus):

```
fpga/sim/run_all.sh                                   # vlog/vsim in PATH, or
QUESTA_BIN=/path/to/questa_fse/win64 fpga/sim/run_all.sh
powershell -File fpga\sim\run_all.ps1 -QuestaBin C:\path\to\questa_fse\win64
```

Expected result for v0.18:

```
tb_burst: RESULT: PASS (15 checks)
tb_manu: RESULT: PASS (6 checks)
tb_fm: RESULT: PASS (3 checks)
tb_ttl: RESULT: PASS (4 checks)
tb_adjp: RESULT: PASS (9 checks)
tb_spi: RESULT: PASS (25 checks)
```

`tb_spi` needs the precompiled Intel libraries `altera_mf_ver` and `lpm_ver` (PLL and DDR
output models); the others only need the design files. The testbenches are run from the
`fpga/` directory because they read `sine8192.hex`.

## Other tools

* `tools/sim_edge_interp.py` – bit-accurate model of the square-wave edge interpolation and
  an estimate of the edge jitter after an ideal 50 MHz low-pass (needs numpy).
