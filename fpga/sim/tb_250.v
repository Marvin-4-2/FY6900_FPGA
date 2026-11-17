`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_250 - second sample per clock (250 MSPS)
// =====================================================================================
// Every clock the channel delivers two samples: dac (phase) and dac_b (half a phase step
// later). For table waveforms both must be the table value at their exact phase, with the
// same latency, also with FM (the half step follows the modulated increment). The
// testbench models the wave RAM of the top level (port A at phase, port B at addr_b).
// Square waves repeat the first sample, a burst in its idle state outputs the idle value
// twice.
// =====================================================================================
module tb_250;
    reg clk = 0; always #4 clk = ~clk;
    reg [63:0] freq = 64'd600_000_000;          // 60 MHz in 0.1 Hz
    reg [2:0]  mode = 3'd0;
    reg [6:0]  mm   = 7'd0;
    reg [23:0] bsrc = 24'd0;
    reg [13:0] m2   = 14'h2000;
    reg [11:0] amd  = 12'd0;
    wire [47:0] phase; wire [12:0] addr_b; wire [13:0] dac, dac_b;
    reg  [13:0] ram [0:8191];
    initial $readmemh("sine8192.hex", ram);
    reg  [13:0] wq = 14'd0, wq_b = 14'd0;
    always @(posedge clk) begin wq <= ram[phase[47:35]]; wq_b <= ram[addr_b]; end
    dds_ch dut (.clk(clk), .run(1'b1), .freq(freq), .kfreq(35'h3_6F9B_FB3B), .ph_load(1'b0), .ph_val(20'd0), .mode(mode),
        .duty(18'h10000), .r_gain(32'd0), .r_width(32'h0007_0007), .phase(phase), .wq(wq), .dac(dac),
        .inc_ext(48'd0), .inc2_ext(48'd0), .addr_b(addr_b), .wq_b(wq_b), .dac_b(dac_b),
        .mod_mode(mm), .mod_sig(m2), .am_depth(amd), .mod_freq(64'd50_000_000), .pm_dev(18'd0),
        .bsrc_n(bsrc), .manu(1'b1), .ext_ac(1'b0), .ext_dc(1'b0), .ext_mod(12'h800), .pw(32'd0));

    // history of the phase and of the increment in effect, sampled after every clock edge
    reg [47:0] ph_h [0:63];
    reg [47:0] ie_h [0:63];
    integer n = 0;
    always @(negedge clk) begin
        ph_h[n % 64] = phase;
        ie_h[n % 64] = dut.inc_eff;
        n = n + 1;
    end

    integer n_check = 0, n_fail = 0;
    task check(input [511:0] what, input ok); begin
        n_check = n_check + 1;
        if (ok) $display("PASS %0s", what); else begin $display("FAIL %0s", what); n_fail = n_fail + 1; end
    end endtask

    // compare dac / dac_b with the table at the exact phase for 'len' clocks
    // latency: dac after edge n belongs to the phase after edge n-9
    task run_table(input integer len, input [511:0] what);
        integer i, bad_a, bad_b, near_b, m;
        reg [47:0] pa, ie, pb;
        begin
            bad_a = 0; bad_b = 0; near_b = 0;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk); #1;
                m  = n - 1;                                   // index of the current sample
                pa = ph_h[(m - 9) % 64];
                ie = ie_h[(m - 10) % 64];
                pb = pa + (ie >> 1);
                if (dac !== ram[pa[47:35]]) bad_a = bad_a + 1;
                // the address of the second sample is computed from the upper 24 phase bits:
                // one table step off is allowed only within 2^25 of a table step boundary
                if (dac_b !== ram[pb[47:35]]) begin
                    if ((dac_b === ram[pb[47:35] + 13'd1] || dac_b === ram[pb[47:35] - 13'd1]) &&
                        (pb[34:0] < 35'h200_0000 || pb[34:0] > 35'h7_FE00_0000)) near_b = near_b + 1;
                    else bad_b = bad_b + 1;
                end
            end
            $display("     %0s: %0d samples, A wrong %0d, B wrong %0d, B at a step boundary %0d", what, len, bad_a, bad_b, near_b);
            check(what, bad_a == 0 && bad_b == 0);
        end
    endtask

    task run_same(input integer len, input [511:0] what);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk); #1;
                if (dac_b !== dac) bad = bad + 1;
            end
            check(what, bad == 0);
        end
    endtask

    // AM with a constant modulation signal (static envelope):
    //   kind 0: envelope 0 -> both samples at the centre (+-2)
    //   kind 1: envelope about 1 -> both samples = 8192 + ((table - 8192) * egn >>> 12), exact
    //   kind 2: envelope about 0.5 -> the second sample is scaled exactly like the first
    //           (same table value -> same output value)
    integer y_of [0:16383];
    task run_am(input integer len, input integer kind, input [511:0] what);
        integer i, bad, cmp, m, xa, xb, ya, yb;
        reg [47:0] pa, pb;
        begin
            bad = 0; cmp = 0;
            for (i = 0; i < 16384; i = i + 1) y_of[i] = -1;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk); #1;
                m  = n - 1;
                pa = ph_h[(m - 9) % 64];
                pb = pa + (ie_h[(m - 10) % 64] >> 1);
                xa = ram[pa[47:35]]; xb = ram[pb[47:35]];
                if (pb[34:0] >= 35'h200_0000 && pb[34:0] <= 35'h7_FE00_0000) begin   // not at a step boundary
                    if (kind == 0) begin
                        if (dac > 8194 || dac < 8190 || dac_b > 8194 || dac_b < 8190) bad = bad + 1;
                        cmp = cmp + 1;
                    end else if (kind == 1) begin
                        ya = 8192 + (((xa - 8192) * dut.egn) >>> 12);
                        yb = 8192 + (((xb - 8192) * dut.egn) >>> 12);
                        if (dac != ya || dac_b != yb) bad = bad + 1;
                        cmp = cmp + 1;
                    end else begin
                        y_of[xa] = dac;
                        if (y_of[xb] != -1) begin cmp = cmp + 1; if (dac_b != y_of[xb]) bad = bad + 1; end
                    end
                end
            end
            $display("     %0s: %0d samples compared, %0d wrong", what, cmp, bad);
            check(what, bad == 0 && cmp > 100);
        end
    endtask

    // FM modulation signal: triangle-like ramp
    reg fm_on = 0;
    always @(posedge clk) if (fm_on) m2 <= m2 + 14'd37;

    initial begin
        repeat (200) @(posedge clk);
        run_table(4000, "sine 60 MHz: both samples at their exact phase");
        freq = 64'd123_456_789;                          // 12.3456789 MHz
        repeat (200) @(posedge clk);
        run_table(4000, "sine 12.3456789 MHz");
        freq = {32'd12345, 32'd10_000};                  // 1.0001234 kHz (uHz remainder)
        repeat (200) @(posedge clk);
        run_table(4000, "sine 1.0001234 kHz");
        freq = 64'd200_000_000;                          // 20 MHz carrier, FM 5 MHz deviation
        mm = 7'h20; fm_on = 1;
        repeat (200) @(posedge clk);
        run_table(4000, "FM: second sample follows the modulated increment");
        fm_on = 0; mm = 7'd0;
        // AM, 60 MHz carrier, depth register at maximum
        freq = 64'd600_000_000; mm = 7'h08; amd = 12'd2047;
        m2 = 14'h0000; repeat (200) @(posedge clk);
        run_am(2000, 0, "AM envelope 0: both samples at the centre");
        m2 = 14'h3FFF; repeat (200) @(posedge clk);
        run_am(2000, 1, "AM envelope 1: both samples = table value x envelope gain");
        m2 = 14'h2000; repeat (200) @(posedge clk);
        run_am(20000, 2, "AM envelope 0.5: second sample scaled like the first");
        mm = 7'd0; amd = 12'd0;
        mode = 3'd1;                                     // square: second sample = first
        repeat (50) @(posedge clk);
        run_same(2000, "square: second sample repeats the first");
        mode = 3'd0; bsrc = {4'd3, 20'd5};              // burst, MANU source, not pressed: idle
        repeat (50) @(posedge clk);
        run_same(2000, "burst idle: both samples show the idle value");
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
