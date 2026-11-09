`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_burst - BURST mode and keyed modulation (FSK) of one DDS channel
// =====================================================================================
// Checks that a burst outputs exactly N full periods per trigger for every trigger source
// (MANU key, CH2, Ext.(AC) = Counter input, Ext.(DC) = Trig IN), also at 50 and 60 MHz where
// phase overflows are only two clocks apart, that retriggering during a burst is ignored,
// that the channel runs continuously without a burst source, and that FSK is keyed by an
// external input and by the MANU key.
//
// Periods are counted as phase overflows (MSB 1 -> 0); edges of the square output are
// counted as well for information.
// =====================================================================================
module tb_burst;
    reg clk = 0; always #4 clk = ~clk;               // 125 MHz
    reg [63:0] freq = 64'd10_000_000;                // 1 MHz in 0.1 Hz
    reg [6:0]  mm   = 7'h10;                         // register 0x21 = 0x10: BURST (no mode bit)
    reg [23:0] bsrc = {4'd3, 20'd3};                 // register 0x19: source MANU, 3 periods
    reg        manu = 1'b1;                          // MANU key released
    reg [13:0] m2   = 14'h0000;                      // CH2 value (modulation / trigger source)
    reg        eac = 1'b0, edc = 1'b0;               // Ext.(AC), Ext.(DC)
    wire [47:0] phase; wire [13:0] dac;

    dds_ch dut (.clk(clk), .run(1'b1), .freq(freq), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(3'd1),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(phase), .wq(14'h2000), .dac(dac),
        .mod_mode(mm), .mod_sig(m2), .am_depth(12'd0), .mod_freq(64'd20_000_000), .pm_dev(18'd0),
        .bsrc_n(bsrc), .manu(manu), .ext_ac(eac), .ext_dc(edc), .ext_mod(12'h800), .pw(32'd0));

    // count rising edges of the square (threshold = mid scale), phase overflows and burst clocks
    integer edges = 0, wraps = 0, runc = 0; reg hi_prev = 0, msb_prev = 0;
    always @(posedge clk) begin
        hi_prev <= dac[13];
        if (dac[13] && !hi_prev) edges = edges + 1;
        msb_prev <= phase[47];
        if (msb_prev && !phase[47]) wraps = wraps + 1;
        if (dut.b_run) runc = runc + 1;
    end

    integer n_check = 0, n_fail = 0;
    task wait_n(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) @(posedge clk); end endtask
    task clear; begin edges = 0; wraps = 0; runc = 0; end endtask
    task check_periods(input [255:0] what, input integer exp);
        begin
            n_check = n_check + 1;
            if (wraps == exp) $display("PASS %0s: %0d periods (edges %0d, burst %0d clocks)", what, wraps, edges, runc);
            else begin
                $display("FAIL %0s: %0d periods, expected %0d (edges %0d, burst %0d clocks)", what, wraps, exp, edges, runc);
                n_fail = n_fail + 1;
            end
            clear;
        end
    endtask
    task check_range(input [255:0] what, input integer val, input integer lo, input integer hi);
        begin
            n_check = n_check + 1;
            if (val >= lo && val <= hi) $display("PASS %0s: %0d (expected %0d..%0d)", what, val, lo, hi);
            else begin $display("FAIL %0s: %0d (expected %0d..%0d)", what, val, lo, hi); n_fail = n_fail + 1; end
        end
    endtask

    integer i;
    initial begin
        wait_n(3000); clear;                                  // let f2inc settle
        wait_n(2000); check_periods("idle, source MANU", 0);
        check_range("idle output is low", dac, 0, 0);
        manu = 0; wait_n(20); manu = 1; wait_n(1500); check_periods("MANU, N=3, 1 MHz", 3);
        check_range("output low after the burst", dac, 0, 0);
        manu = 0; wait_n(20); manu = 1; wait_n(1500); check_periods("MANU again", 3);

        // source CH2: three rising edges of CH2 -> three bursts of 2 periods
        bsrc = {4'd1, 20'd2}; wait_n(10); clear;
        for (i = 0; i < 3; i = i + 1) begin m2 = 14'h3FFF; wait_n(600); m2 = 14'h0000; wait_n(600); end
        check_periods("CH2, 3 triggers, N=2", 6);

        // Ext.(DC), N = 5 at 50 MHz and 60 MHz (overflows only two clocks apart)
        bsrc = {4'd4, 20'd5}; freq = 64'd500_000_000; wait_n(3000); clear;
        edc = 1; wait_n(50); edc = 0; wait_n(200); check_periods("Ext.(DC), N=5, 50 MHz", 5);
        freq = 64'd600_000_000; wait_n(3000); clear;
        edc = 1; wait_n(50); edc = 0; wait_n(200); check_periods("Ext.(DC), N=5, 60 MHz", 5);
        // Ext.(AC), N = 1
        bsrc = {4'd2, 20'd1}; freq = 64'd10_000_000; wait_n(3000); clear;
        eac = 1; wait_n(50); eac = 0; wait_n(1000); check_periods("Ext.(AC), N=1", 1);
        // a second trigger during the burst is ignored
        bsrc = {4'd2, 20'd4}; wait_n(10); clear;
        eac = 1; wait_n(20); eac = 0; wait_n(100); eac = 1; wait_n(20); eac = 0; wait_n(1500);
        check_periods("retrigger ignored, N=4", 4);

        // no burst source any more -> continuous output, 1 MHz, 1000 clocks = 8 us
        bsrc = {4'd0, 20'd2}; wait_n(20); clear; wait_n(1000);
        check_range("continuous output, edges in 8 us", edges, 7, 9);

        // FSK keyed by Ext.(DC): keyed -> 2 MHz (hop frequency), otherwise 1 MHz
        mm = 7'h02; bsrc = {4'd4, 20'd2}; edc = 0; wait_n(20); clear; wait_n(1000);
        check_range("FSK Ext.(DC)=0, edges in 8 us", edges, 7, 9);
        edc = 1; wait_n(20); clear; wait_n(1000);
        check_range("FSK Ext.(DC)=1, edges in 8 us", edges, 15, 17);
        // FSK keyed by MANU: key pressed (0) = hop frequency
        bsrc = {4'd3, 20'd2}; manu = 1; wait_n(20); clear; wait_n(1000);
        check_range("FSK MANU released, edges in 8 us", edges, 7, 9);
        manu = 0; wait_n(20); clear; wait_n(1000);
        check_range("FSK MANU pressed, edges in 8 us", edges, 15, 17);
        manu = 1;

        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
