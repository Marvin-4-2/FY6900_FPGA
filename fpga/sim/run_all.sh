#!/usr/bin/env bash
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
# =====================================================================================
# Run all testbenches with Questa (Intel FPGA Starter/Lite edition, installed with Quartus).
#
#   fpga/sim/run_all.sh                      # vlib/vlog/vsim must be in PATH
#   QUESTA_BIN=/path/to/questa/bin fpga/sim/run_all.sh
#
# The script works in the fpga/ directory (the testbenches read sine8192.hex from there) and
# prints the RESULT line of every testbench. Exit code 1 if any testbench fails.
# =====================================================================================
set -u
cd "$(dirname "$0")/.."
B="${QUESTA_BIN:+$QUESTA_BIN/}"

"${B}vlib" work > /dev/null
"${B}vlog" -quiet fy_fpga.v freq_counter.v sim/tb_*.v || exit 1

fail=0
for tb in tb_burst tb_manu tb_fm tb_ttl tb_adjp tb_spi; do
    out=$("${B}vsim" -c -quiet -L altera_mf_ver -L lpm_ver "$tb" -do "run -all; quit -f" 2>&1)
    res=$(echo "$out" | grep "RESULT:" | head -1)
    echo "$tb: ${res:-RESULT: no result (simulation error)}"
    case "$res" in *PASS*) ;; *) fail=1; echo "$out" | grep -E "FAIL|Error" ;; esac
done
exit $fail
