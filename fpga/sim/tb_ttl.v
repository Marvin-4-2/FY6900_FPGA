`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_ttl - position of the TTL sync edges relative to the DAC output
// =====================================================================================
// The TTL outputs (Port A-D, Sync OUT) are delayed so that their edges line up with the
// analog output. This testbench measures, for a 1 MHz signal, the time between the DAC
// crossing mid scale and the TTL edge for sine, square (30 % duty) and trapezoid, the
// high time of the TTL signal and the level with the channel switched off (mode 7).
// Run from the fpga/ directory (reads sine8192.hex).
// =====================================================================================
module tb_ttl;
    reg clk = 0; always #4 clk = ~clk;
    reg [2:0] mode = 3'd0;
    reg [13:0] tbl [0:8191]; initial $readmemh("sine8192.hex", tbl);
    reg [13:0] wq = 14'h2000;
    wire [47:0] phase; wire [13:0] dac; wire ttl, ttl_on;
    always @(posedge clk) wq <= tbl[phase[47:35]];              // wave RAM model
    dds_ch dut (.clk(clk), .run(1'b1), .freq(64'd10_000_000), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(mode),
        .duty(18'd39322), .r_gain({4'd0, 14'd2340, 14'd2340}), .r_width({4'd0, 14'd7, 14'd7}), .phase(phase), .wq(wq), .dac(dac),
        .ttl(ttl), .ttl_on(ttl_on), .ttl_early(),
        .mod_mode(7'd0), .mod_sig(14'h2000), .am_depth(12'd0), .mod_freq(64'd0), .pm_dev(18'd0),
        .bsrc_n(24'd0), .manu(1'b1), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(32'd0));
    reg ttl_o = 0; always @(posedge clk) ttl_o <= ttl;           // output register as in the top level
    integer t_ttl_r, t_dac_r, t_ttl_f, t_dac_f; reg tp = 0, dp = 0;
    always @(posedge clk) begin
        tp <= ttl_o; dp <= (dac >= 14'h2000);
        if (ttl_o && !tp) t_ttl_r = $time;
        if (!ttl_o && tp) t_ttl_f = $time;
        if ((dac >= 14'h2000) && !dp) t_dac_r = $time;
        if (!(dac >= 14'h2000) && dp) t_dac_f = $time;
    end
    integer n_check = 0, n_fail = 0;
    task check(input [255:0] what, input ok); begin
        n_check = n_check + 1;
        if (ok) $display("PASS %0s", what); else begin $display("FAIL %0s", what); n_fail = n_fail + 1; end
    end endtask
    // measure over two periods; dr/df = TTL edge minus DAC mid-scale crossing, hi = TTL high time
    integer dr, df, hi;
    task meas(input [63:0] name); begin
        #20000;
        dr = t_ttl_r - t_dac_r; df = t_ttl_f - t_dac_f;
        hi = (t_ttl_f > t_ttl_r) ? t_ttl_f - t_ttl_r : 1000 - (t_ttl_r - t_ttl_f);
        $display("     %0s: TTL rises %0d ns, falls %0d ns after the DAC mid-scale crossing, high %0d of 1000 ns", name, dr, df, hi);
    end endtask
    initial begin
        #30000;
        mode = 3'd0; #5000; meas("sine     ");
        check("sine: edges aligned (0 ns), 50 % high", dr == 0 && df == 0 && hi >= 496 && hi <= 512);
        mode = 3'd1; #5000; meas("square   ");
        check("square: edges within one clock, 30 % high", dr >= -8 && dr <= 8 && df >= -8 && df <= 8 && hi >= 296 && hi <= 312);
        mode = 3'd2; #5000; meas("trapezoid");
        check("trapezoid: edges within one clock", dr >= -8 && dr <= 8 && df >= -8 && df <= 8);
        mode = 3'd7; #5000; #3000;
        $display("     off: ttl=%0d ttl_on=%0d", ttl_o, ttl_on);
        check("channel off: TTL low, inverted output disabled", ttl_o == 1'b0 && ttl_on == 1'b0);
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
