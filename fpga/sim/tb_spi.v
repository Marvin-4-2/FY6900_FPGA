`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_spi - complete top level with the SPI access patterns of STM32 firmware 1.8.0
// =====================================================================================
// Emulates the STM32 (SPI mode 3, 16-bit words, REGSEL, software CS) and checks:
//   - reads of the ID registers 0x1F and 0x3A
//   - writes, also mixed with 16-bit VCO-IN frames (no bit counter misalignment)
//   - VCO-IN samples land in register 0x2D and drive the modulation signal
//   - uplink slave: a rising edge at Sync IN reloads the start phase, no effect when off
//   - uplink master: Sync OUT carries the early (undelayed) phase reference
//   - frequency calibration: K computed from registers 0x22:0x23, limits and fallback
// Needs the Intel simulation libraries altera_mf_ver and lpm_ver (altpll, altddio_out) and
// must be run from the fpga/ directory (reads sine8192.hex).
// =====================================================================================
module tb_spi;
    reg sync_in = 0;
    reg clk10 = 0; always #50 clk10 = ~clk10;        // 10 MHz TCXO
    reg sck = 1, mosi = 0, cs_n = 1, regsel = 1;     // SPI mode 3: SCK idles high
    wire miso;
    fy_fpga dut (.clk10(clk10), .spi_sck(sck), .spi_mosi(mosi), .spi_cs_n(cs_n), .spi_regsel(regsel),
        .spi_miso(miso), .fl_miso(1'b1), .cnt_in(1'b0), .trig_in(1'b0), .sync_in(sync_in));

    // ---- STM32 SPI primitives (as in the firmware's FPGA_Write / FPGA_Read) ----
    task bit_out(input b, output r); begin
        sck = 0; mosi = b; #50; sck = 1; r = miso; #50;
    end endtask
    task xfer16(input [15:0] v, output [15:0] r); integer i; reg rb; begin
        for (i = 15; i >= 0; i = i - 1) begin bit_out(v[i], rb); r[i] = rb; end
    end endtask
    reg [15:0] dummy, hi, lo;
    task fpga_write(input [7:0] a, input [31:0] d); begin
        regsel = 0; #20 cs_n = 0; #100; xfer16({8'd0, a}, dummy); regsel = 1; #50;
        xfer16(d[31:16], dummy); xfer16(d[15:0], dummy); #50 cs_n = 1; #400;
    end endtask
    task fpga_read(input [7:0] a, output [31:0] d); begin
        regsel = 0; #20 cs_n = 0; #100; xfer16({8'd0, a}, dummy); #50 cs_n = 1; #200;
        regsel = 1; #600 cs_n = 0; #100; xfer16(16'd0, hi); xfer16(16'd0, lo); d = {hi, lo}; #50 cs_n = 1; #400;
    end endtask
    task vco(input [15:0] v); begin   // VCO-IN sample: REGSEL stays high, only CS + 16 bits
        regsel = 1; #20 cs_n = 0; #100; xfer16(v, dummy); #50 cs_n = 1; #400;
    end endtask

    // ---- checks ----
    integer n_check = 0, n_fail = 0;
    task check(input [255:0] what, input ok); begin
        n_check = n_check + 1;
        if (ok) $display("PASS %0s", what); else begin $display("FAIL %0s", what); n_fail = n_fail + 1; end
    end endtask
    task expect_reg(input [5:0] a, input [31:0] v, input [255:0] what); begin
        n_check = n_check + 1;
        if (dut.regs[a] !== v) begin $display("FAIL %0s: reg %h = %h, expected %h", what, a, dut.regs[a], v); n_fail = n_fail + 1; end
        else $display("PASS %0s: reg %h = %h", what, a, v);
    end endtask
    task kchk(input [63:0] r, input [34:0] k, input [255:0] what); begin
        fpga_write(8'h22, r[63:32]); fpga_write(8'h23, r[31:0]); #3000;
        n_check = n_check + 1;
        if (dut.kfreq !== k) begin $display("FAIL %0s: K = %h, expected %h", what, dut.kfreq, k); n_fail = n_fail + 1; end
        else $display("PASS %0s: K = %h", what, k);
    end endtask

    reg [31:0] rv;
    integer k;
    reg ttl1_early_d0 = 0; always @(posedge dut.clk) ttl1_early_d0 <= dut.ttl1_early;
    initial begin
        wait (dut.locked); #2000;
        // ID registers
        fpga_read(8'h3A, rv); check("R 3A = 0x00FB6910 (ID polled by firmware 1.8.0)", rv === 32'h00FB6910);
        fpga_read(8'h1F, rv); check("R 1F = 0x10 (FPGA ID)", rv === 32'h10);
        fpga_write(8'h07, 32'h000186A0); expect_reg(6'h07, 32'h000186A0, "W 07");
        // VCO-IN as in firmware 1.8.0: W 21 = 0x18 (AM + external source), W 2D = 0x800, 16-bit frames
        fpga_write(8'h21, 32'h18); fpga_write(8'h2D, 32'h800); expect_reg(6'h2D, 32'h800, "W 2D centre");
        vco(16'h0ABC); expect_reg(6'h2D, 32'h0ABC, "VCO frame 1");
        fpga_write(8'h2E, 32'h123); expect_reg(6'h2E, 32'h123, "write after one VCO frame (alignment)");
        vco(16'h0FFF); vco(16'h0001); vco(16'h07FF); expect_reg(6'h2D, 32'h07FF, "three VCO frames");
        fpga_write(8'h09, 32'h12345678); expect_reg(6'h09, 32'h12345678, "write after three VCO frames");
        fpga_read(8'h3A, rv); check("read after VCO frames", rv === 32'h00FB6910);
        expect_reg(6'h2D, 32'h07FF, "register 0x2D unchanged by a read");
        for (k = 0; k < 5; k = k + 1) begin vco(16'h0100 + k); fpga_write(8'h30, 32'h10000 + k); end
        expect_reg(6'h2D, 32'h0104, "VCO frames mixed with writes"); expect_reg(6'h30, 32'h10004, "writes mixed with VCO frames");
        // modulation signal in the channel: (0x104 - 0x800) * 8
        #200; check("VCO-IN drives the modulation signal", dut.u_ch1.m_s == (32'sh104 - 32'sh800) * 8);
        // Uplink slave: CH1 1 MHz, register 05 bits 6:5 = 11 -> Sync IN edge reloads the phase
        fpga_write(8'h21, 32'h10); fpga_write(8'h06, 32'h0); fpga_write(8'h07, 32'd10_000_000); fpga_write(8'h0A, 32'h40000);
        fpga_write(8'h05, 32'h1E0); #5000;
        @(posedge dut.clk); #1 sync_in = 1;
        wait (dut.ul_sync); @(posedge dut.clk); #1;
        check("uplink slave: Sync IN edge loads the start phase", dut.u_ch1.acc[47:28] == 20'h40000);
        #3000 sync_in = 0;
        fpga_write(8'h05, 32'h1C0); #2000; sync_in = 1; #500;
        check("uplink off: Sync IN has no effect", dut.ul_sync === 1'b0);
        sync_in = 0;
        // Uplink master: Sync OUT follows the early phase reference (2 clocks later)
        fpga_write(8'h05, 32'h180); #3000;
        k = 0; repeat (2000) begin @(posedge dut.clk); #1; if (dut.sync_out !== ttl1_early_d0) k = k + 1; end
        check("uplink master: Sync OUT = early phase reference", k == 0);
        // Frequency calibration: K from registers 0x22:0x23
        check("K = default before the first write", dut.kfreq === 35'h3_6F9B_FB3B);
        kchk(64'h0000_E35F_A931_A000, 35'h3_6F9B_FB3B, "R = 2.5e14 (X = 10 MHz)");
        kchk(64'h0000_E365_7B4F_5A00, 35'h3_6F85_7733, "X = 10.001 MHz");
        kchk(64'h0000_E35D_5525_BC00, 35'h3_6FA4_FD2A, "X = 9.9996 MHz");
        kchk(64'h0000_DFF6_8BC6_A400, 35'h3_7D01_1E3E, "X = 9.85 MHz");
        kchk(64'h0000_DED3_81F8_5000, 35'h3_6F9B_FB3B, "X = 9.8 MHz (out of range -> default)");
        kchk(64'h0000_E7EB_D06A_F000, 35'h3_5E5C_B008, "X = 10.2 MHz (limit)");
        kchk(64'h0001_0000_0000_0000, 35'h3_6F9B_FB3B, "implausible value -> default");
        kchk(64'h0000_E35F_A931_A000, 35'h3_6F9B_FB3B, "back to 10 MHz");
        if (n_fail == 0) $display("RESULT: PASS (%0d checks)", n_check);
        else             $display("RESULT: FAIL (%0d of %0d checks failed)", n_fail, n_check);
        $finish;
    end
endmodule
