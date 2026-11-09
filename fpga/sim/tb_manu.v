`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_manu - BURST with the MANU source, register sequence of STM32 firmware 1.8.0
// =====================================================================================
// Firmware 1.8.0 first writes burst count 0 when MANU is selected (and pulses register
// 0x18), only the OK key writes the real count and pulses 0x18 again. This testbench
// replays that sequence: burst with CH2 -> select MANU (must stay silent) -> OK (N periods)
// -> OK again -> count reduced during a running burst -> back to CH2.
// =====================================================================================
module tb_manu;
    reg clk = 0; always #4 clk = ~clk;               // 125 MHz
    reg [6:0]  mm   = 7'h10;                         // BURST
    reg [23:0] bsrc = {4'd1, 20'd3};                 // source CH2, 3 periods
    reg        manu = 1'b1;
    reg [13:0] m2   = 14'h0000;
    wire [47:0] phase; wire [13:0] dac;
    dds_ch dut (.clk(clk), .run(1'b1), .freq(64'd10_000_000), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(3'd1),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(phase), .wq(14'h2000), .dac(dac),
        .mod_mode(mm), .mod_sig(m2), .am_depth(12'd0), .mod_freq(64'd0), .pm_dev(18'd0),
        .bsrc_n(bsrc), .manu(manu), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(32'd0));

    // CH2 square with a period of 1000 clocks (one burst trigger every 8 us)
    always begin #4000 m2 = 14'h3FFF; #4000 m2 = 14'h0000; end

    integer wraps = 0, runc = 0; reg msb_prev = 0;
    always @(posedge clk) begin
        msb_prev <= phase[47];
        if (msb_prev && !phase[47]) wraps = wraps + 1;
        if (dut.b_run) runc = runc + 1;
    end
    integer n_check = 0, n_fail = 0;
    task wait_n(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) @(posedge clk); end endtask
    task check(input [255:0] what, input integer exp); begin
        n_check = n_check + 1;
        if (wraps == exp) $display("PASS %0s: %0d periods (burst %0d clocks)", what, wraps, runc);
        else begin $display("FAIL %0s: %0d periods, expected %0d (burst %0d clocks)", what, wraps, exp, runc); n_fail = n_fail + 1; end
        wraps = 0; runc = 0; end endtask
    initial begin
        wait_n(3000); wraps = 0; runc = 0;
        wait_n(5000); check("source CH2, 5 triggers x N=3", 15);
        // firmware 1.8.0 selects MANU: W 19 = 3<<20 (count 0), W 21 = 0x10, W 18 = 0, W 18 = 1
        bsrc = {4'd3, 20'd0}; wait_n(300); mm = 7'h10; manu = 0; wait_n(300); manu = 1;
        wait_n(5000); check("MANU selected, count 0 -> silent", 0);
        // OK key: W 19 = 3 | 3<<20, W 18 = 0, W 18 = 1
        bsrc = {4'd3, 20'd3}; wait_n(300); manu = 0; wait_n(300); manu = 1; wait_n(5000); check("MANU OK", 3);
        bsrc = {4'd3, 20'd3}; wait_n(300); manu = 0; wait_n(300); manu = 1; wait_n(5000); check("MANU OK again", 3);
        // count reduced during the burst: N = 100, after 2000 clocks (16 periods) N = 3
        // -> the burst stops at the next period boundary
        bsrc = {4'd3, 20'd100}; wait_n(300); manu = 0; wait_n(300); manu = 1; wait_n(2000);
        bsrc = {4'd3, 20'd3}; wait_n(5000); check("count reduced during the burst", 16);
        bsrc = {4'd1, 20'd3}; wait_n(5000); check("back to source CH2", 15);
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
