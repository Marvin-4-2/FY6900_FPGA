# FPGA project

| File | Content |
|---|---|
| `fy_fpga.v` | top level (PLL, SPI slave, register file, flash controller, wave RAMs, calibration, channel instances, DDR outputs and DAC clocks, relays, TTL/sync outputs), modules `dds_ch` (one DDS channel incl. modulation and waveforms, two samples per clock), `f2inc` (frequency → phase increment), `f2inc3` (one converter shared by three frequencies), `mcp_drv` (MCP4822 driver) |
| `freq_counter.v` | frequency / event counter and pulse width measurement |
| `fy_fpga.qpf`, `fy_fpga.qsf` | Quartus project and settings, pin assignments |
| `fy_fpga.sdc` | timing constraints |
| `sine8192.hex`, `gen_sine.py` | power-on content of the wave RAMs and its generator |
| `sim/` | testbenches and run scripts |

Build: `quartus_sh --flow compile fy_fpga` (Quartus Prime Lite, Cyclone IV E). The design is
described in [../docs/fpga-design.md](../docs/fpga-design.md); building and simulation in
[../docs/simulation.md](../docs/simulation.md).

The parameters `DAC1_PHASE_PS` and `DAC2_PHASE_PS` (top level) set the phase of the 250 MHz
DAC clocks relative to the data (2000 ps = rising edge in the middle of the 4 ns data window,
clean on the test unit). If a channel shows short spikes on steep edges on another unit that
do not depend on the cabling, this is the parameter to try first (250 ps steps).
