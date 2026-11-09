`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_fm - FM symmetry and PM scale
// =====================================================================================
// A symmetric square modulation must not shift the mean frequency: after 200 modulation
// periods the modulated channel must have exactly the same phase as an unmodulated
// reference channel. (A modulation signal centred on 8192 instead of 8191.5 caused a
// carrier offset of -deviation/16384, which made the picture drift on the scope.)
// PM with a deviation of 90 deg (0x8000) must give +-2^46 (minus one LSB step of the
// modulation signal).
// =====================================================================================
module tb_fm;
    reg clk = 0; always #4 clk = ~clk;
    reg [13:0] m2 = 14'h0000;
    reg [6:0]  mm = 7'h20;                     // FM
    wire [47:0] ph_a, ph_b; wire [13:0] d_a, d_b;
    // a: modulated channel (1 kHz carrier, 5 kHz deviation, PM deviation 90 deg)
    dds_ch a (.clk(clk), .run(1'b1), .freq(64'd10_000), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(3'd0),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(ph_a), .wq(14'h2000), .dac(d_a),
        .mod_mode(mm), .mod_sig(m2), .am_depth(12'd0), .mod_freq(64'd50_000), .pm_dev(18'd32768),
        .bsrc_n(24'd0), .manu(1'b1), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(32'd0));
    // b: unmodulated reference
    dds_ch b (.clk(clk), .run(1'b1), .freq(64'd10_000), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(3'd0),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(ph_b), .wq(14'h2000), .dac(d_b),
        .mod_mode(7'd0), .mod_sig(14'h2000), .am_depth(12'd0), .mod_freq(64'd0), .pm_dev(18'd0),
        .bsrc_n(24'd0), .manu(1'b1), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(32'd0));
    task wait_n(input integer n); integer i; begin for (i = 0; i < n; i = i + 1) @(posedge clk); end endtask
    integer k, n_check = 0, n_fail = 0;
    reg signed [47:0] d0, d1;
    task check(input [255:0] what, input ok); begin
        n_check = n_check + 1;
        if (ok) $display("PASS %0s", what); else begin $display("FAIL %0s", what); n_fail = n_fail + 1; end
    end endtask
    initial begin
        wait_n(3000);
        d0 = ph_a - ph_b;
        for (k = 0; k < 200; k = k + 1) begin m2 = 14'h3FFF; wait_n(500); m2 = 14'h0000; wait_n(500); end
        d1 = ph_a - ph_b;
        $display("     FM drift after 200 modulation periods: %0d LSB", d1 - d0);
        check("FM: no mean frequency offset (drift = 0)", (d1 - d0) == 0);
        // PM 90 deg: offset with CH2 at the top / bottom
        mm = 7'h40; m2 = 14'h3FFF; wait_n(20);
        $display("     PM +: pm_off = %h", a.pm_off);
        check("PM +90 deg = 0x3fff00000000", a.pm_off == 48'h3fff_0000_0000);
        m2 = 14'h0000; wait_n(20);
        $display("     PM -: pm_off = %h", a.pm_off);
        check("PM -90 deg = 0xc00100000000", a.pm_off == 48'hc001_0000_0000);
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
