`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_adjp - Adj-Pulse: fixed pulse width (register 0x1D in 4 ns units) at any frequency
// =====================================================================================
// The high time is measured from the DAC value (unipolar 0x2000..0x3FFF): the sum of the
// fractions above mid scale per clock. This includes the sub-sample edge interpolation, so
// even 4 ns steps (half a clock) must come out exactly.
// =====================================================================================
module tb_adjp;
    reg clk = 0; always #4 clk = ~clk;
    reg [63:0] freq = 64'd10_000;          // 1 kHz
    reg [31:0] pw   = 32'd25_000;          // 100 us
    reg [2:0]  mode = 3'd4;                // Adj-Pulse
    wire [47:0] phase; wire [13:0] dac; wire ttl, ttl_on;
    dds_ch dut (.clk(clk), .run(1'b1), .freq(freq), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(mode),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(phase), .wq(14'h2000), .dac(dac),
        .ttl(ttl), .ttl_on(ttl_on), .ttl_early(),
        .mod_mode(7'd0), .mod_sig(14'h2000), .am_depth(12'd0), .mod_freq(64'd0), .pm_dev(18'd0),
        .bsrc_n(24'd0), .manu(1'b1), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(pw));
    real hi_ns;
    integer n_check = 0, n_fail = 0;
    // settle for one period, then integrate the high fraction over one period
    task measure(input [255:0] what, input real expect_ns, input integer period_clk);
        integer i; real a; begin
        repeat (period_clk) @(posedge clk);
        a = 0;
        for (i = 0; i < period_clk; i = i + 1) begin
            @(posedge clk); a = a + (dac - 14'h2000) / 8191.0;   // high fraction of this clock
        end
        hi_ns = a * 8.0;
        n_check = n_check + 1;
        if (hi_ns > expect_ns - 0.5 && hi_ns < expect_ns + 0.5)
            $display("PASS %0s: high time per period %0.2f ns", what, hi_ns);
        else begin
            $display("FAIL %0s: high time per period %0.2f ns, expected %0.2f", what, hi_ns, expect_ns);
            n_fail = n_fail + 1;
        end
    end endtask
    initial begin
        #20000;
        measure("1 kHz, 100 us", 100000.0, 125000);
        freq = 64'd20_000; measure("2 kHz, 100 us (width unchanged)", 100000.0, 62500);
        freq = 64'd1_000_000; pw = 32'd25; measure("100 kHz, 100 ns", 100.0, 1250);
        pw = 32'd26; measure("100 kHz, 104 ns", 104.0, 1250);
        pw = 32'd27; measure("100 kHz, 108 ns", 108.0, 1250);
        freq = 64'd100; pw = 32'd25; measure("10 Hz, 100 ns", 100.0, 12500000);
        freq = 64'd10_000; pw = 32'd300_000; measure("1 kHz, 1.2 ms (longer than the period -> always high)", 1000000.0, 125000);
        pw = 32'd0; measure("1 kHz, width 0 -> no pulse", 0.0, 125000);
        mode = 3'd3; pw = 32'd25; measure("CMOS 50 % (width ignored)", 500000.0, 125000);
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
