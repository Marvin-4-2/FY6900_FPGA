# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
# =====================================================================================
# FY6900 replacement FPGA - timing constraints
# =====================================================================================

# 10 MHz TCXO (pin 23)
create_clock -name clk10 -period 100.000 [get_ports clk10]
# SPI clock from the STM32 (18 MHz nominal, constrained with margin)
create_clock -name spi_sck -period 55.000 [get_ports spi_sck]
# Counter inputs clock the event counter directly (target up to 125 MHz)
create_clock -name cnt_in -period 8.000 [get_ports cnt_in]
create_clock -name trig_in -period 8.000 [get_ports trig_in]
derive_pll_clocks
derive_clock_uncertainty

# The SPI domain, the system domain, the pulse width domain and the counter inputs are
# asynchronous to each other (all crossings use toggle synchronisation or double sampling)
set_clock_groups -asynchronous -group [get_clocks spi_sck] -group [get_clocks {clk10 u_pll|auto_generated|pll1|clk[0] u_pll|auto_generated|pll1|clk[1]}] -group [get_clocks {u_pll|auto_generated|pll1|clk[2]}] -group [get_clocks {cnt_in trig_in}]
# Counter input and Trig IN are never active at the same time (multiplexer, register 0x05 bit 4)
set_clock_groups -logically_exclusive -group [get_clocks cnt_in] -group [get_clocks trig_in]

# The MCP4822 driver (clk10) samples the register values twice -> no synchronous path
set_false_path -from [get_clocks {u_pll|auto_generated|pll1|clk[0]}] -to [get_clocks clk10]
