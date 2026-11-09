# FPGA project

| File | Content |
|---|---|
| `fy_fpga.v` | top level (PLL, SPI slave, register file, flash controller, wave RAMs, calibration, channel instances, DAC clocks, relays, TTL/sync outputs), modules `dds_ch` (one DDS channel incl. modulation and waveforms), `f2inc` (frequency → phase increment), `mcp_drv` (MCP4822 driver) |
| `freq_counter.v` | frequency / event counter and pulse width measurement |
| `fy_fpga.qpf`, `fy_fpga.qsf` | Quartus project and settings, pin assignments |
| `fy_fpga.sdc` | timing constraints |
| `sine8192.hex`, `gen_sine.py` | power-on content of the wave RAMs and its generator |
| `sim/` | testbenches and run scripts |

Build: `quartus_sh --flow compile fy_fpga` (Quartus Prime Lite, Cyclone IV E). The design is
described in [../docs/fpga-design.md](../docs/fpga-design.md); building and simulation in
[../docs/simulation.md](../docs/simulation.md).

The parameter `DAC2_PHASE_PS` (top level) sets the phase of the CH2 DAC clock. 6000 ps was
found to be free of latch errors on the test unit; if CH2 shows short spikes on steep edges
on another unit, this is the parameter to try first.
