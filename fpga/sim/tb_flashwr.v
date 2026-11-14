`timescale 1ns/1ps
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// tb_flashwr - guarded flash writes (sector erase / byte program) with a W25Q flash model
// =====================================================================================
// The STM32 side replays the register sequence of the firmware's custom waveform upload
// (identical in 1.4.2, 0x08016B14, and 1.8.0, 0x0801724C):
//   W13=0, W11=0, poll R15; 4 x { W17=sector, W11=1, W11=0, poll R15 }; W17=slot;
//   W16=1, W16=0; n x { W14=byte, W13=1, poll R15, W13=0 }; W16=0; poll R15
// against a behavioural W25Q16/W25Q32 model that wraps addresses like the real chip, and
// checks:
//   - the JEDEC ID read at start-up sets the write limit (2 MB, 4 MB, none if unknown)
//   - a slot is erased and programmed, the data are stored in the scrambled flash format,
//     and a waveform load (W12) brings the samples back into the wave RAM
//   - single-byte reads (W0D / R0C) still work
//   - nothing below 0x05A000 (bitstream area) is ever erased or programmed, also not for a
//     slot that starts just below 0x05A000 (only its part from 0x05A000 on is written)
//   - addresses at or beyond the flash size are refused instead of wrapping around
// Three top-level modules run the same test with different flash models:
//   tb_flash16 (W25Q16, ID EF 40 15), tb_flash32 (W25Q32, ID EF 40 16),
//   tb_flashid (unknown ID FF FF FF: no writes at all).
// Needs altera_mf_ver and lpm_ver; run from the fpga/ directory (reads sine8192.hex).
// =====================================================================================

// -------------------------------------------------------------------------------------
// Behavioural model of a Winbond W25Qxx SPI flash (mode 0): commands 0x03 read, 0x9F JEDEC
// ID, 0x05 status register 1, 0x06 write enable, 0x20 sector erase, 0x02 page program.
// Addresses wrap at the chip size like on the real device. Counters for the checks:
//   n_erase / n_prog : executed erase / program commands
//   n_low            : erased or programmed bytes / sectors below 0x05A000
//   n_wrap           : erase / program commands with an address >= the chip size
// -------------------------------------------------------------------------------------
module w25q_model #(
    parameter integer SIZE  = 2097152,
    parameter [23:0]  JEDEC = 24'hEF4015
) (
    input  wire clk,
    input  wire cs_n,
    input  wire mosi,
    output reg  miso = 1'b1
);
    localparam integer T_SE = 30000;   // erase time in ns (real chip: typ. 45 ms, shortened)
    localparam integer T_PP = 1000;    // program time in ns (real chip: ~30 us for a byte)

    reg [7:0]  mem [0:SIZE-1];
    reg [7:0]  cmd = 8'h00;
    reg [39:0] sh = 40'd0;
    integer    nbits = 0;
    reg [23:0] addr = 24'd0;
    integer    raddr = 0;
    reg [7:0]  obyte = 8'hFF;
    integer    obit = 7;
    reg [7:0]  pbuf [0:255];
    integer    pcnt = 0;
    reg        wel = 1'b0, busy = 1'b0;
    integer    tbusy = 0;
    integer    n_erase = 0, n_prog = 0, n_low = 0, n_wrap = 0;
    integer    i, a, base;
    event      ev_busy;

    // initial content: "bitstream" 0xA5 below 0x05A000, 0x00 elsewhere (so a missing erase
    // shows up: programming can only clear bits)
    initial for (i = 0; i < SIZE; i = i + 1) mem[i] = (i < 32'h05A000) ? 8'hA5 : 8'h00;

    always @(ev_busy) begin #(tbusy) busy = 1'b0; end

    always @(negedge cs_n) begin nbits = 0; cmd = 8'h00; pcnt = 0; end

    // inputs are sampled on the rising clock edge
    always @(posedge clk) if (!cs_n) begin
        sh = {sh[38:0], mosi};
        nbits = nbits + 1;
        if (nbits == 8) cmd = sh[7:0];
        if (nbits == 32 && (cmd == 8'h03 || cmd == 8'h02 || cmd == 8'h20)) begin
            addr = sh[23:0];
            if (cmd == 8'h03) begin raddr = addr % SIZE; obyte = mem[raddr]; obit = 7; end
        end
        if (cmd == 8'h02 && nbits > 32 && ((nbits - 32) % 8) == 0) begin
            if (pcnt < 256) pbuf[pcnt] = sh[7:0];
            pcnt = pcnt + 1;
        end
    end

    // outputs change on the falling clock edge
    always @(negedge clk) if (!cs_n) begin
        if (cmd == 8'h03 && nbits >= 32) begin
            miso = obyte[obit];
            if (obit == 0) begin raddr = (raddr + 1) % SIZE; obyte = mem[raddr]; obit = 7; end
            else obit = obit - 1;
        end else if (cmd == 8'h9F && nbits >= 8 && nbits < 32) begin
            miso = JEDEC[23 - (nbits - 8)];
        end else if (cmd == 8'h05 && nbits >= 8) begin
            case ((nbits - 8) % 8)
                6:       miso = wel;
                7:       miso = busy;
                default: miso = 1'b0;
            endcase
        end
    end

    // commands are executed when chip select rises
    always @(posedge cs_n) begin
        if (cmd == 8'h06 && nbits == 8) begin
            if (!busy) wel = 1'b1;
        end else if (cmd == 8'h20 && nbits == 32) begin
            if (wel && !busy) begin
                base = addr % SIZE; base = base - (base % 4096);
                for (i = 0; i < 4096; i = i + 1) mem[base + i] = 8'hFF;
                n_erase = n_erase + 1;
                if (base < 32'h05A000) n_low = n_low + 1;
                if (addr >= SIZE) n_wrap = n_wrap + 1;
                wel = 1'b0; busy = 1'b1; tbusy = T_SE; -> ev_busy;
            end
        end else if (cmd == 8'h02 && nbits >= 40 && (nbits % 8) == 0) begin
            if (wel && !busy) begin
                base = addr % SIZE; base = base - (base % 256);
                for (i = 0; i < pcnt && i < 256; i = i + 1) begin
                    a = base + ((addr + i) % 256);          // wraps within the page
                    mem[a] = mem[a] & pbuf[i];
                    if (a < 32'h05A000) n_low = n_low + 1;
                end
                n_prog = n_prog + 1;
                if (addr >= SIZE) n_wrap = n_wrap + 1;
                wel = 1'b0; busy = 1'b1; tbusy = T_PP; -> ev_busy;
            end
        end
    end
endmodule

// -------------------------------------------------------------------------------------
// Test core: one DUT with one flash model, parameterised by the flash type
// -------------------------------------------------------------------------------------
module flashwr_core #(
    parameter integer SIZE  = 2097152,
    parameter [23:0]  JEDEC = 24'hEF4015,
    parameter [23:0]  LIM   = 24'h200000      // expected write limit (0 = no writes)
) ();
    reg clk10 = 0; always #50 clk10 = ~clk10;        // 10 MHz TCXO
    reg sck = 1, mosi = 0, cs_n = 1, regsel = 1;     // SPI mode 3: SCK idles high
    wire miso;
    wire fclk, fcs_n, fmosi, fmiso;
    fy_fpga dut (.clk10(clk10), .spi_sck(sck), .spi_mosi(mosi), .spi_cs_n(cs_n), .spi_regsel(regsel),
        .spi_miso(miso), .fl_clk(fclk), .fl_cs_n(fcs_n), .fl_mosi(fmosi), .fl_miso(fmiso),
        .cnt_in(1'b0), .trig_in(1'b0), .sync_in(1'b0));
    w25q_model #(.SIZE(SIZE), .JEDEC(JEDEC)) flash (.clk(fclk), .cs_n(fcs_n), .mosi(fmosi), .miso(fmiso));

    // ---- STM32 SPI primitives (as in tb_spi) ----
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

    // ---- checks ----
    integer n_check = 0, n_fail = 0;
    task check(input [1023:0] what, input ok); begin
        n_check = n_check + 1;
        if (ok) $display("PASS %0s", what); else begin $display("FAIL %0s", what); n_fail = n_fail + 1; end
    end endtask

    // ---- firmware sequences ----
    integer busy_seen = 0;
    task poll; reg [31:0] v; integer n; begin       // while (R15 != 0)
        v = 32'd1; n = 0;
        while (v[0]) begin
            fpga_read(8'h15, v); n = n + 1;
            if (v[0]) busy_seen = busy_seen + 1;
            if (n > 20000) begin $display("FAIL busy never cleared"); n_fail = n_fail + 1; v = 0; end
        end
    end endtask

    // test data: byte j of the slot that starts at base
    function [7:0] dbyte(input [23:0] base, input integer j);
        dbyte = (j * 37 + base[19:12] * 11 + 5) & 8'hFF;
    endfunction
    // expected flash byte for data byte v (permutation as measured on the stock design:
    // v0->f5, v1->f3, v2->f6, v3->f1, v4->f0, v5->f7, v6->f2, v7->f4)
    function [7:0] scr_tb(input [7:0] v); begin
        scr_tb = 8'd0;
        scr_tb[5] = v[0]; scr_tb[3] = v[1]; scr_tb[6] = v[2]; scr_tb[1] = v[3];
        scr_tb[0] = v[4]; scr_tb[7] = v[5]; scr_tb[2] = v[6]; scr_tb[4] = v[7];
    end endfunction
    // single-byte read return value for flash byte f: {f3, f5, f0, f1, f6, f4, f2, f7}
    function [7:0] ret_tb(input [7:0] f);
        ret_tb = {f[3], f[5], f[0], f[1], f[6], f[4], f[2], f[7]};
    endfunction

    // custom waveform upload of n bytes to the slot at base (16 KB = 4 sectors erased)
    task save(input [23:0] base, input integer n); integer j; begin
        fpga_write(8'h13, 0); fpga_write(8'h11, 0); poll;
        for (j = 0; j < 4; j = j + 1) begin
            fpga_write(8'h17, base + j * 24'h1000); fpga_write(8'h11, 1); fpga_write(8'h11, 0); poll;
        end
        fpga_write(8'h17, base); fpga_write(8'h16, 1); fpga_write(8'h16, 0);
        for (j = 0; j < n; j = j + 1) begin
            fpga_write(8'h14, dbyte(base, j)); fpga_write(8'h13, 1); poll; fpga_write(8'h13, 0);
        end
        fpga_write(8'h16, 0); poll;
    end endtask

    // compare flash content: bytes from..to-1 of the slot at base
    function integer slot_errors(input [23:0] base, input integer from, input integer to,
                                 input integer n, input written);
        integer j, e; reg [7:0] exp;
        begin
            e = 0;
            for (j = from; j < to; j = j + 1) begin
                if (!written)  exp = (base + j < 32'h05A000) ? 8'hA5 : 8'h00;
                else if (j < n) exp = scr_tb(dbyte(base, j));
                else           exp = 8'hFF;                     // erased, not programmed
                if (flash.mem[(base + j) % SIZE] !== exp) e = e + 1;
            end
            slot_errors = e;
        end
    endfunction

    reg [31:0] rv;
    integer j, e;
    reg [13:0] s;
    initial begin
        wait (dut.locked);
        wait (dut.id_done); #1000;
        check("JEDEC ID read at start-up", dut.fl_id === JEDEC);
        check("flash size from the JEDEC ID",
              dut.fl_size === ((LIM == 24'h200000) ? 2'd1 : (LIM == 24'h400000) ? 2'd2 : 2'd0));

        // 1. normal upload: firmware 1.8.0 slot 1 at 0x1A0000, 300 bytes (crosses a page)
        busy_seen = 0;
        save(24'h1A0000, 300);
        check("slot 0x1A0000: 300 bytes stored scrambled (or untouched without writes)",
              slot_errors(24'h1A0000, 0, 300, 300, LIM != 0) == 0);
        check("slot 0x1A0000: rest of the slot erased (or untouched without writes)",
              slot_errors(24'h1A0000, 300, 16384, 300, LIM != 0) == 0);
        if (LIM != 0) check("busy reported while erasing / programming", busy_seen > 0);
        else          check("no busy without writes", busy_seen == 0);

        // 2. load the slot as a waveform into CH1: the samples must come back
        fpga_write(8'h17, 24'h1A0000); fpga_write(8'h0F, 1); fpga_write(8'h12, 1); poll; fpga_write(8'h12, 0);
        e = 0;
        for (j = 0; j < 150; j = j + 1) begin
            s = (LIM != 0) ? {dbyte(24'h1A0000, 2*j+1), dbyte(24'h1A0000, 2*j)} : 14'd0;
            if (dut.wave1[j] !== s) e = e + 1;
        end
        check("waveform load returns the uploaded samples", e == 0);

        // 3. single-byte read (firmware pulses 1, 1, 0, 0)
        fpga_write(8'h17, 24'h1A0001);
        fpga_write(8'h0D, 1); fpga_write(8'h0D, 1); fpga_write(8'h0D, 0); fpga_write(8'h0D, 0); poll;
        fpga_read(8'h0C, rv);
        check("single-byte read", rv[7:0] === ret_tb((LIM != 0) ? scr_tb(dbyte(24'h1A0000, 1)) : 8'h00));

        // 4. bitstream area: 1.8.0 slots 25 and 47 after wrapping on a W25Q16
        save(24'h000000, 16);
        save(24'h058000, 16);
        // 5. slot starting 8 bytes below 0x05A000: only the part from 0x05A000 on is written
        save(24'h059FF8, 16);
        check("bytes from 0x05A000 of a slot starting at 0x059FF8 written",
              slot_errors(24'h059FF8, 8, 16, 16, LIM != 0) == 0);
        if (LIM != 0)
            check("sector 0x05A000 erased behind them",
                  slot_errors(24'h059FF8, 16, 4096, 16, 1) == 0);

        // 6. firmware 1.8.0 slot 25: 0x200000 (beyond a W25Q16, inside a W25Q32)
        save(24'h200000, 16);
        if (LIM == 24'h400000)
            check("slot 0x200000 written on a 4 MB flash",
                  slot_errors(24'h200000, 0, 4096, 16, 1) == 0);

        // global checks
        e = 0;
        for (j = 0; j < 32'h05A000; j = j + 1) if (flash.mem[j] !== 8'hA5) e = e + 1;
        check("bitstream area 0x000000-0x059FFF unchanged", e == 0);
        check("nothing below 0x05A000 erased or programmed", flash.n_low == 0);
        check("no erase / program beyond the flash size (no wrap-around)", flash.n_wrap == 0);
        if (LIM == 0)
            check("unknown flash: no erase / program command at all",
                  flash.n_erase == 0 && flash.n_prog == 0);
        else
            check("expected number of program commands",
                  flash.n_prog == 300 + 8 + ((LIM == 24'h400000) ? 16 : 0));

        $display("RESULT: %0s (%0d checks)", (n_fail == 0) ? "PASS" : "FAIL", n_check);
        $finish;
    end
endmodule

// -------------------------------------------------------------------------------------
// Top levels
// -------------------------------------------------------------------------------------
module tb_flash16;   // W25Q16: writes 0x05A000..0x1FFFFF
    flashwr_core #(.SIZE(2097152), .JEDEC(24'hEF4015), .LIM(24'h200000)) core ();
endmodule

module tb_flash32;   // W25Q32: writes 0x05A000..0x3FFFFF
    flashwr_core #(.SIZE(4194304), .JEDEC(24'hEF4016), .LIM(24'h400000)) core ();
endmodule

module tb_flashid;   // no valid JEDEC ID: no writes at all
    flashwr_core #(.SIZE(2097152), .JEDEC(24'hFFFFFF), .LIM(24'h000000)) core ();
endmodule
