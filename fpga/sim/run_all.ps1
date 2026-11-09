# SPDX-License-Identifier: CERN-OHL-S-2.0
# Copyright 2026 The FY6900_FPGA contributors
# Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
# Source location: https://github.com/Marvin-4-2/FY6900_FPGA
# =====================================================================================
# Run all testbenches with Questa (Intel FPGA Starter/Lite edition, installed with Quartus).
#
#   powershell -File fpga\sim\run_all.ps1
#   powershell -File fpga\sim\run_all.ps1 -QuestaBin "C:\intelFPGA_lite\questa_fse\win64"
#
# Works in the fpga\ directory (the testbenches read sine8192.hex from there) and prints the
# RESULT line of every testbench. Exit code 1 if any testbench fails.
# =====================================================================================
param([string]$QuestaBin = "")

$fpga = Split-Path -Parent $PSScriptRoot
Push-Location $fpga
try {
    function Tool($name) { if ($QuestaBin) { Join-Path $QuestaBin $name } else { $name } }
    & (Tool "vlib") work | Out-Null
    & (Tool "vlog") -quiet fy_fpga.v freq_counter.v (Get-ChildItem sim\tb_*.v | ForEach-Object { $_.FullName })
    if ($LASTEXITCODE -ne 0) { exit 1 }
    $fail = $false
    foreach ($tb in @("tb_burst", "tb_manu", "tb_fm", "tb_ttl", "tb_adjp", "tb_spi")) {
        $out = & (Tool "vsim") -c -quiet -L altera_mf_ver -L lpm_ver $tb -do "run -all; quit -f" 2>&1 | Out-String
        $res = ($out -split "`n" | Where-Object { $_ -match "RESULT:" } | Select-Object -First 1)
        if (-not $res) { $res = "RESULT: no result (simulation error)" }
        Write-Output "${tb}: $($res.Trim())"
        if ($res -notmatch "PASS") {
            $fail = $true
            $out -split "`n" | Where-Object { $_ -match "FAIL|Error" } | ForEach-Object { Write-Output $_ }
        }
    }
    if ($fail) { exit 1 }
} finally {
    Pop-Location
}
