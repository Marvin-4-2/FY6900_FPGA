// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
// =====================================================================================
// FY6900 replacement FPGA design - top level
// =====================================================================================
//
// Target:   FeelTech FY6900 (60 MHz), FPGA board V2.1, Intel/Altera Cyclone IV E EP4CE6E22C8N
// Firmware: works with the stock STM32 front-panel firmware (tested with 1.8.0, 1.4.2 compatible)
// Version:  0.19
//
// The design re-implements the register interface that the stock STM32 firmware expects from
// the original FPGA bitstream. The firmware, its user interface and all of its menus stay
// unchanged. See docs/spi-protocol.md and docs/registers.md for the interface and
// docs/fpga-design.md for an explanation of the architecture.
//
// Functional overview
//   - SPI slave for the STM32 (mode 3, 16-bit words, separate address/data phase via REGSEL)
//   - 64 x 32-bit register file, toggle-synchronised into the 125 MHz system clock domain
//   - SPI flash controller (W25Q16 / W25Q32): loads waveforms into the wave RAMs, answers
//     single-byte reads for the STM32 and stores uploaded custom waveforms (sector erase, byte
//     program) behind a write guard that protects the bitstream area and never wraps around
//   - two DDS channels (module dds_ch) at 125 MSPS with 48-bit phase accumulators:
//       table waveforms (8192 x 14 bit), square/rectangle with sub-sample edge interpolation,
//       trapezoid, CMOS/pulse (unipolar), Adj-Pulse with fixed pulse width, DC/off
//   - modulation of CH1: AM, FM, PM, ASK, FSK, PSK and BURST; sources CH2, Counter input,
//     Trig IN, MANU (OK key) and VCO-IN (sampled by the STM32 ADC and streamed over SPI)
//   - MCP4822 drivers for amplitude and offset, output range relays
//   - frequency counter / event counter / pulse width measurement (freq_counter.v)
//   - TTL outputs (Port A-D), Sync OUT, Sync IN (uplink master/slave)
//   - frequency calibration: the DDS follows the reference value the firmware writes
//
// Flash writes are guarded: nothing below 0x05A000 (bitstream area) and nothing beyond the
// flash size read from the JEDEC ID (see docs/fpga-design.md, flash writes).
// =====================================================================================

module fy_fpga #(
    // Phase shift of the CH2 DAC clock in picoseconds (PLL output clk1). 6000 ps = 270 deg at
    // 125 MHz. The CH2 DAC clock pin (129) sits next to the MSB (128); without this shift the
    // clock edge coincided with the data transitions and produced spikes on steep edges.
    parameter DAC2_PHASE_PS = "6000"
) (
    input  wire        clk10,         // 10 MHz TCXO (pin 23, CLK1)
    // SPI from the STM32 (front panel)
    input  wire        spi_sck,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,
    input  wire        spi_regsel,    // low = address phase, high = data phase
    output wire        spi_miso,
    // SPI flash W25Q16 on the configuration pins (regular I/O after configuration)
    output reg         fl_clk  = 1'b0,
    output reg         fl_cs_n = 1'b1,
    output reg         fl_mosi = 1'b0,
    input  wire        fl_miso,
    // DAC-1412 channel 1 / channel 2 (14 bit, straight binary, latches on the rising clock edge)
    output wire        dac_clk,
    output wire [13:0] dac_d,
    output wire        dac2_clk,
    output wire [13:0] dac2_d,
    // MCP4822 channel 1 / channel 2 (amplitude and offset)
    output wire        mcp_cs_n, mcp_sck, mcp_sdi, mcp_ldac_n,
    output wire        mcp2_cs_n, mcp2_sck, mcp2_sdi, mcp2_ldac_n,
    // Output range relays (register 0x05 bits 3..0)
    output reg         rly_ch1_big   = 1'b0,
    output reg         rly_ch1_small = 1'b0,
    output reg         rly_ch2_big   = 1'b0,
    output reg         rly_ch2_small = 1'b0,
    // Counter inputs: "Counter" BNC (AC coupled front end) and "Trig IN" (DC, via 74HC245)
    input  wire        cnt_in,
    input  wire        trig_in,
    input  wire        sync_in,       // Sync IN BNC (rear panel)
    // TTL outputs on the rear pin header (via 74HC245):
    //   Port A = CH1 0 deg, Port B = CH1 180 deg, Port C = CH2 0 deg, Port D = CH2 180 deg
    output reg         ttl_a = 1'b0,
    output reg         ttl_b = 1'b0,
    output reg         ttl_c = 1'b0,
    output reg         ttl_d = 1'b0,
    // Sync OUT BNC (rear panel): CH1 phase reference (high while phase < 180 deg or < duty).
    // Uplink (user manual: all units run synchronously to the start phase of the master;
    // firmware commands UUL/UMS set register 0x05 bits 6:5 = 10 off, 00 master, 11 slave):
    // the master outputs the reference without the output pipeline delay (partly compensates
    // the slave's input latency), a slave reloads both phase accumulators on every rising edge
    // at Sync IN.
    output reg         sync_out = 1'b0
);

    // ---------------------------------------------------------------------------------
    // PLL: 10 MHz -> 125 MHz system clock (the DAC-1412 is specified up to 125 MSPS)
    // ---------------------------------------------------------------------------------
    wire [4:0] pll_clk;
    wire       locked;
    altpll #(
        .intended_device_family ("Cyclone IV E"), .lpm_type ("altpll"),
        .operation_mode ("NORMAL"), .pll_type ("AUTO"), .bandwidth_type ("AUTO"),
        .compensate_clock ("CLK0"), .inclk0_input_frequency (100000),
        // clk0: 125 MHz system clock (DDS, register file, flash controller)
        .clk0_multiply_by (25), .clk0_divide_by (2), .clk0_duty_cycle (50), .clk0_phase_shift ("0"),
        // clk1: CH2 DAC clock, shifted so that its rising edge comes DAC2_PHASE_PS after the
        //       data transition
        .clk1_multiply_by (25), .clk1_divide_by (2), .clk1_duty_cycle (50), .clk1_phase_shift (DAC2_PHASE_PS),
        // clk2: 125 MHz for the counter's pulse width measurement (8 ns steps, reported in
        //       4 ns units)
        .clk2_multiply_by (25), .clk2_divide_by (2), .clk2_duty_cycle (50), .clk2_phase_shift ("0"),
        .width_clock (5),
        .port_inclk0 ("PORT_USED"), .port_inclk1 ("PORT_UNUSED"),
        .port_clk0 ("PORT_USED"), .port_clk1 ("PORT_USED"), .port_clk2 ("PORT_USED"),
        .port_clk3 ("PORT_UNUSED"), .port_clk4 ("PORT_UNUSED"),
        .port_locked ("PORT_USED"), .port_areset ("PORT_UNUSED")
    ) u_pll (.inclk ({1'b0, clk10}), .clk (pll_clk), .locked (locked));
    wire clk = pll_clk[0];

    // ---------------------------------------------------------------------------------
    // SPI slave (SCK clock domain), SPI mode 3
    //   Write:      CS low, REGSEL low: 16-bit address, REGSEL high: 32-bit data, CS high
    //   Read:       address frame, CS high, then a 32-bit data frame (data on MISO)
    //   ReadAgain:  data frame only (re-reads the last address, used for busy polling)
    //   VCO-IN:     data frame with exactly 16 bits and no address (see below)
    // Completed address/data words are handed to the system clock domain with toggle flags.
    // ---------------------------------------------------------------------------------
    reg [3:0]  acnt = 4'd0;               // address bit counter
    reg [15:0] addr_sr = 16'd0, addr_lat = 16'd0;
    reg        addr_tog = 1'b0;           // toggles after every complete address
    reg [4:0]  dcnt = 5'd0;               // data bit counter (also selects the MISO bit)
    reg [31:0] data_sr = 32'd0, data_lat = 32'd0;
    reg        data_tog = 1'b0;           // toggles after every complete 32-bit data word
    reg        fa = 1'b0;                 // address bits were received in this frame
    reg        v16 = 1'b0;                // frame so far = exactly 16 data bits without address
    reg [15:0] v_lat = 16'h0800;          // VCO-IN sample (16-bit data frame)

    // Reset the bit counters while CS is high: every frame starts aligned, even after frames
    // of a different length (VCO-IN frames have 16 bits). All accesses of the STM32 are
    // complete within one CS frame.
    always @(posedge spi_sck or posedge spi_cs_n)
        if (spi_cs_n)          begin acnt <= 4'd0; dcnt <= 5'd0; fa <= 1'b0; end
        else if (!spi_regsel)  begin acnt <= acnt + 4'd1; fa <= 1'b1; end
        else                         dcnt <= dcnt + 5'd1;

    always @(posedge spi_sck) begin
        if (!spi_cs_n) begin
            if (!spi_regsel) begin
                addr_sr <= {addr_sr[14:0], spi_mosi};
                v16     <= 1'b0;
                if (acnt == 4'd15) begin
                    addr_lat <= {addr_sr[14:0], spi_mosi};
                    addr_tog <= ~addr_tog;
                end
            end else begin
                data_sr <= {data_sr[30:0], spi_mosi};
                if (dcnt == 5'd31) begin
                    data_lat <= {data_sr[30:0], spi_mosi};
                    data_tog <= ~data_tog;
                end
                // VCO-IN: with an external AM/FM/PM source the STM32 continuously sends frames
                // with CS low, REGSEL high and 16 bits = ADC value (0..4095, centre 0x800) but no
                // address. The value is taken over when CS rises and the last bit received was
                // exactly the 16th data bit.
                v16 <= !fa && (dcnt == 5'd15);
                if (dcnt == 5'd15) v_lat <= {data_sr[14:0], spi_mosi};
            end
        end
    end

    // MISO: the read word is shifted out MSB first, the bit index follows the data counter
    reg [31:0] rd_word = 32'd0;
    assign spi_miso = rd_word[5'd31 - dcnt];

    // ---------------------------------------------------------------------------------
    // System clock domain: synchronisation and register file
    // ---------------------------------------------------------------------------------
    reg [2:0] cs_s = 3'b111, at_s = 3'b000, dt_s = 3'b000;
    always @(posedge clk) begin
        cs_s <= {cs_s[1:0], spi_cs_n};
        at_s <= {at_s[1:0], addr_tog};
        dt_s <= {dt_s[1:0], data_tog};
    end
    wire cs_rise = (cs_s[2:1] == 2'b01);      // end of an SPI frame

    reg        at_seen = 1'b0, dt_seen = 1'b0, at_prev = 1'b0;
    reg        ph_sync = 1'b0;   // pulse: register 0x2F written (apply phases, sync channels)
    reg        kc_wr   = 1'b0;   // pulse: register 0x22/0x23 written (frequency calibration)
    reg        a17_wr  = 1'b0;   // pulse: register 0x17 written (flash address -> write pointer)
    reg [5:0]  rd_addr = 6'd0;
    reg [31:0] regs [0:63];
    integer k;
    initial begin
        for (k = 0; k < 64; k = k + 1) regs[k] = 32'd0;
        regs[6'h29] = 32'h7FF;   // CH1 offset centred until the firmware writes it
        regs[6'h2A] = 32'h7FF;   // CH2 offset centred
        regs[6'h30] = 32'h10000; // duty 50 %
        regs[6'h31] = 32'h10000;
        regs[6'h18] = 32'd1;     // MANU key released (firmware: pressed = 0, released = 1)
    end

    // A write is committed at the end of the frame when both an address and a data word
    // arrived in the same frame. A read frame only delivers an address (rd_addr), the
    // following data frame only delivers data, so neither of them writes a register.
    always @(posedge clk) begin
        at_prev <= at_s[2];
        if (at_s[2] != at_prev)
            rd_addr <= addr_lat[5:0];
        ph_sync <= 1'b0;
        kc_wr   <= 1'b0;
        a17_wr  <= 1'b0;
        if (cs_rise) begin
            if ((at_s[2] != at_seen) && (dt_s[2] != dt_seen)) begin
                regs[addr_lat[5:0]] <= data_lat;
                if (addr_lat[5:0] == 6'h2F) ph_sync <= 1'b1;   // apply phase settings
                if (addr_lat[5:0] == 6'h22 || addr_lat[5:0] == 6'h23) kc_wr <= 1'b1;   // reference changed
                if (addr_lat[5:0] == 6'h17) a17_wr <= 1'b1;    // flash address (write pointer)
            end else if (v16) begin
                regs[6'h2D] <= {20'd0, v_lat[11:0]};            // VCO-IN sample (W 2D = 0x800 sets the centre)
            end
            at_seen <= at_s[2];
            dt_seen <= dt_s[2];
        end
    end

    // ---------------------------------------------------------------------------------
    // Frequency counter (freq_counter.v)
    // ---------------------------------------------------------------------------------
    wire [31:0] cnt_rd02, cnt_rd03;
    // Register 0x05 bit 4 ("COUPLING" in the counter menu): 0 = AC = Counter input (pin 135),
    // 1 = DC = Trig IN (pin 144). There is no coupling switch in hardware, only this
    // multiplexer. The selected input clocks the event counter and is routed as a global clock.
    reg         cnt_sel = 1'b0;
    always @(posedge clk) cnt_sel <= regs[6'h05][4];
    (* keep *) wire cnt_src = cnt_sel ? trig_in : cnt_in;   // global clock net (see .qsf)

    // External modulation / burst sources: Ext.(AC) = Counter input, Ext.(DC) = Trig IN
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] xac_s = 2'b00;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] xdc_s = 2'b00;
    always @(posedge clk) begin
        xac_s <= {xac_s[0], cnt_in};
        xdc_s <= {xdc_s[0], trig_in};
    end
    freq_counter u_cnt (
        .clk (clk), .clk125 (pll_clk[2]), .fin (cnt_src),
        .ctrl (regs[6'h01][7:0]),
        .gate_1s (regs[6'h24]), .gate_10s (regs[6'h25]),
        .gate_100s ({regs[6'h26][1:0], regs[6'h27]}),
        .rd02 (cnt_rd02), .rd03 (cnt_rd03)
    );

    // Flash controller status (see below)
    reg        fl_busy = 1'b0;
    reg        fl_pend = 1'b0;      // a start request is latched but not yet started
    reg [7:0]  fl_rbyte = 8'd0;

    // ---------------------------------------------------------------------------------
    // Read multiplexer. The stock firmware only reads registers 0x02, 0x03, 0x0C, 0x15, 0x1B,
    // 0x1F and 0x3A (all FPGA read calls of firmware 1.4.2 and 1.8.0 were checked). A general
    // register read-back is therefore not implemented, which lets synthesis remove all unused
    // register bits. Two pipeline stages (rd_addr_d, rd_word) for timing at 125 MHz; the
    // STM32 leaves several microseconds between the address and the data frame.
    // ---------------------------------------------------------------------------------
    reg [5:0]  rd_addr_d = 6'd0;
    always @(posedge clk) rd_addr_d <= rd_addr;
    always @(posedge clk) begin
        case (rd_addr_d)
            6'h1F:                rd_word <= 32'h0000_0010;          // FPGA ID (original value 0x10)
            6'h3A:                rd_word <= 32'h00FB_6910;          // ID/version: firmware 1.8.0 waits at power-on up to 200 x 20 ms for bits 23:8 = 0xFB69; bits 7:0 = version (original 0x10)
            6'h15:                rd_word <= {31'd0, fl_busy | fl_pend}; // flash busy (also while a request waits)
            6'h0C:                rd_word <= {24'd0, fl_rbyte};      // flash byte read
            6'h02:                rd_word <= cnt_rd02;               // counter result
            6'h03:                rd_word <= cnt_rd03;               // counter status
            default:              rd_word <= 32'h0000_0000;          // 0x1B (authentication challenge) and all others
        endcase
    end

    // ---------------------------------------------------------------------------------
    // Flash controller: SPI mode 0, 31.25 MHz (125 MHz / 4), W25Q16 / W25Q32
    // ---------------------------------------------------------------------------------
    // Operations, started by a rising edge in a register value (busy in register 0x15):
    //   register 0x12 bit 0: load a waveform: 16384 bytes from address reg 0x17 into the wave
    //                        RAM selected by reg 0x0F (1 = CH1, 2 = CH2)        flash cmd 0x03
    //   register 0x0D bit 0: read a single byte at address reg 0x17 (result in reg 0x0C)  0x03
    //   register 0x11 bit 0: erase the 4 KB sector at the write pointer      0x06, 0x20, 0x05
    //   register 0x13 bit 0: program the byte in reg 0x14 at the write pointer,  0x06, 0x02, 0x05
    //                        then advance the pointer by one
    // The write pointer is loaded by every write to register 0x17. That serves both write
    // routines of the firmware: the waveform upload sets 0x17 once per slot and relies on the
    // increment, the (normally unused) ID routine sets 0x17 before every byte. Every byte is
    // programmed with its own page-program command, so register 0x16 (begin/end of a write
    // sequence for a page buffer in the original design) is not needed and ignored.
    // The data byte is stored bit-permuted like all waveform data (scr below): the firmware
    // passes the plain sample bytes received from the PC software unchanged to register 0x14.
    //
    // Write guard: erase and program are only executed for addresses from 0x05A000 (the
    // bitstream area ends there) up to the end of the flash. The flash size is read from the
    // JEDEC ID once after start-up: Winbond (0xEF) type 0x40/0x70 with capacity code 0x15 = 2 MB
    // (W25Q16), 0x16 = 4 MB (W25Q32); any other ID allows no writes at all. A refused command
    // sends nothing to the flash and is reported as done, so the firmware's upload finishes
    // normally. Firmware 1.8.0 sends custom waveform slots 25..64 to 0x200000..0x29FFFF; on a
    // W25Q16 they are refused instead of wrapping around into the bitstream (the original
    // design wrapped them or redirected them to 0x1B0000, see docs/firmware-notes.md).
    //
    // Start requests are latched (pending flags), so a request that arrives while the JEDEC ID
    // is being read is not lost; register 0x15 reads busy while a request is pending.
    reg r12_prev = 1'b0, r0d_prev = 1'b0, r11_prev = 1'b0, r13_prev = 1'b0;
    reg p12 = 1'b0, p0d = 1'b0, p11 = 1'b0, p13 = 1'b0;     // pending start requests

    // Bit order of single-byte reads: the original FPGA returns flash byte f as
    //   o[7:0] = {f3, f5, f0, f1, f6, f4, f2, f7}
    // and the firmware undoes this permutation in software.
    function [7:0] map_ret(input [7:0] f);
        map_ret = {f[3], f[5], f[0], f[1], f[6], f[4], f[2], f[7]};
    endfunction
    // Waveform bytes are stored bit-permuted in the flash (permutation table at flash
    // 0xF0000). Unscrambling flash byte f gives the value
    //   v[7:0] = {f4, f2, f7, f0, f1, f6, f3, f5}
    function [7:0] unscr(input [7:0] f);
        unscr = {f[4], f[2], f[7], f[0], f[1], f[6], f[3], f[5]};
    endfunction
    // Inverse permutation for writing: data byte v is stored as flash byte
    //   f[7:0] = {v5, v2, v0, v7, v1, v6, v3, v4}      (unscr(scr(v)) = v)
    // This is what the original FPGA writes (measured on the test unit).
    function [7:0] scr(input [7:0] v);
        scr = {v[5], v[2], v[0], v[7], v[1], v[6], v[3], v[4]};
    endfunction

    localparam S_IDLE = 3'd0, S_CMD = 3'd1, S_DATA = 3'd2, S_DONE = 3'd3,
               S_RX   = 3'd4, S_GAP = 3'd5;
    localparam OP_READ = 2'd0, OP_ID = 2'd1, OP_ERASE = 2'd2, OP_PROG = 2'd3;
    reg [2:0]  fst = S_IDLE;
    reg [1:0]  fph = 2'd0;          // clock phase 0..3 (one flash bit = 4 system clocks)
    reg [39:0] fsh = 40'd0;         // shift register: command, address, data (sent MSB first)
    reg [5:0]  fbit = 6'd0;         // bit counter (sending and S_RX)
    reg [5:0]  fnbits = 6'd32;      // number of bits to send in S_CMD
    reg [4:0]  frbits = 5'd0;       // number of bits to receive in S_RX after sending (0 = none)
    reg [23:0] frx = 24'd0;         // bits received in S_RX (JEDEC ID, status register)
    reg [1:0]  fop = OP_READ;       // current operation
    reg [1:0]  fstep = 2'd0;        // erase/program: 0 = write enable, 1 = command, 2 = status poll
    reg [3:0]  fgap = 4'd0;         // S_GAP timer: chip select high between two commands
    reg [26:0] fto = 27'd0;         // erase/program timeout (2^27 clocks = 1.07 s)
    reg [23:0] fop_addr = 24'd0;    // address of the current erase/program command
    reg [7:0]  fop_data = 8'd0;     // flash byte of the current program command (permuted)
    reg [23:0] wr_ptr = 24'd0;      // write pointer, loaded by writes to register 0x17
    reg [1:0]  fl_size = 2'd0;      // flash size from the JEDEC ID: 1 = 2 MB, 2 = 4 MB, 0 = no writes
    reg [23:0] fl_id = 24'd0;       // JEDEC ID (manufacturer, type, capacity)
    reg        id_done = 1'b0;      // JEDEC ID has been read
    reg [10:0] id_wait = 11'd0;     // short delay after the PLL is running (2048 clocks)
    reg        wr_ok = 1'b0;        // write guard result for the write pointer
    reg [7:0]  fin = 8'd0;          // received byte
    reg [2:0]  fbc = 3'd0;          // bit counter within the byte
    reg [14:0] fbytes = 15'd0;      // byte counter (up to 16384)
    reg        fmode_wave = 1'b0;   // 1 = load waveform, 0 = single byte
    reg [1:0]  ftarget = 2'd0;      // wave RAM target (1 = CH1, 2 = CH2)
    reg [7:0]  lo_byte = 8'd0;      // low byte of the current 14-bit sample
    wire [7:0] fin_un = unscr(fin);

    // Write port of the wave RAMs
    reg        w1_we = 1'b0, w2_we = 1'b0;
    reg [12:0] w_addr = 13'd0;
    reg [13:0] w_data = 14'd0;

    always @(posedge clk) begin
        w1_we <= 1'b0;
        w2_we <= 1'b0;
        r12_prev <= regs[6'h12][0];
        r0d_prev <= regs[6'h0D][0];
        r11_prev <= regs[6'h11][0];
        r13_prev <= regs[6'h13][0];
        fl_pend  <= p12 | p0d | p11 | p13 | !id_done;
        if (!id_wait[10]) id_wait <= id_wait + 11'd1;
        // write guard for the write pointer (also the erase address: every write to 0x17 loads
        // the pointer). Registered; the pointer is stable long before the next strobe.
        wr_ok <= (wr_ptr >= 24'h05A000) &&
                 ((fl_size == 2'd1 && wr_ptr[23:21] == 3'd0) ||      // below 2 MB
                  (fl_size == 2'd2 && wr_ptr[23:22] == 2'd0));       // below 4 MB
        if (a17_wr) wr_ptr <= regs[6'h17][23:0];

        case (fst)
        S_IDLE: begin
            fl_cs_n <= 1'b1; fl_clk <= 1'b0;
            fbit <= 6'd0; fph <= 2'd0; fto <= 27'd0;
            if (!id_done) begin
                // once after start-up: read the JEDEC ID (command 0x9F, 24 bits back)
                if (id_wait[10]) begin
                    fop <= OP_ID; fsh <= {8'h9F, 32'd0}; fnbits <= 6'd8; frbits <= 5'd24;
                    fst <= S_CMD; fl_busy <= 1'b1;
                end
            end else if (p12) begin
                p12 <= 1'b0;
                fop <= OP_READ; fmode_wave <= 1'b1; ftarget <= regs[6'h0F][1:0];
                fsh <= {8'h03, regs[6'h17][23:0], 8'h00}; fnbits <= 6'd32; frbits <= 5'd0;
                fst <= S_CMD; fl_busy <= 1'b1;
            end else if (p0d) begin
                p0d <= 1'b0;
                fop <= OP_READ; fmode_wave <= 1'b0;
                fsh <= {8'h03, regs[6'h17][23:0], 8'h00}; fnbits <= 6'd32; frbits <= 5'd0;
                fst <= S_CMD; fl_busy <= 1'b1;
            end else if (p11) begin
                p11 <= 1'b0;
                if (wr_ok) begin   // erase: write enable first; refused: nothing happens
                    fop <= OP_ERASE; fstep <= 2'd0; fop_addr <= wr_ptr;
                    fsh <= {8'h06, 32'd0}; fnbits <= 6'd8; frbits <= 5'd0;
                    fst <= S_CMD; fl_busy <= 1'b1;
                end
            end else if (p13) begin
                p13 <= 1'b0;
                if (wr_ok) begin   // program: write enable first; refused: nothing happens
                    fop <= OP_PROG; fstep <= 2'd0; fop_addr <= wr_ptr;
                    fop_data <= scr(regs[6'h14][7:0]);
                    fsh <= {8'h06, 32'd0}; fnbits <= 6'd8; frbits <= 5'd0;
                    fst <= S_CMD; fl_busy <= 1'b1;
                end
                wr_ptr <= wr_ptr + 24'd1;   // refused bytes advance the pointer as well
            end
        end

        S_CMD: begin                // send fnbits bits of fsh, MSB first
            fl_cs_n <= 1'b0;
            fph <= fph + 2'd1;
            case (fph)
                2'd0: begin fl_clk <= 1'b0; fl_mosi <= fsh[39]; end
                2'd2: fl_clk <= 1'b1;
                2'd3: begin
                    fsh <= {fsh[38:0], 1'b0};
                    fbit <= fbit + 6'd1;
                    if (fbit == fnbits - 6'd1) begin
                        fbit <= 6'd0;
                        if (fop == OP_READ) begin
                            fst <= S_DATA; fbc <= 3'd0; fbytes <= 15'd0; w_addr <= 13'd0;
                        end else if (frbits != 5'd0) begin
                            fst <= S_RX;
                        end else begin
                            fst <= S_GAP; fgap <= 4'd0;
                        end
                    end
                end
                default: ;
            endcase
        end

        S_RX: begin                 // receive frbits bits into frx (JEDEC ID, status register)
            fph <= fph + 2'd1;
            case (fph)
                2'd0: fl_clk <= 1'b0;
                2'd2: begin fl_clk <= 1'b1; frx <= {frx[22:0], fl_miso}; end
                2'd3: begin
                    fbit <= fbit + 6'd1;
                    if (fbit == {1'b0, frbits} - 6'd1) begin fst <= S_GAP; fgap <= 4'd0; end
                end
                default: ;
            endcase
        end

        S_GAP: begin                // end of a command: clock low, chip select high for ~100 ns
            fgap <= fgap + 4'd1;
            if (fgap == 4'd0) fl_clk  <= 1'b0;
            if (fgap == 4'd1) fl_cs_n <= 1'b1;
            if (fgap == 4'd15) begin
                fbit <= 6'd0; fph <= 2'd0;
                if (fop == OP_ID) begin
                    fl_id <= frx;
                    if (frx[23:16] == 8'hEF && (frx[15:8] == 8'h40 || frx[15:8] == 8'h70) &&
                        frx[7:0] == 8'h15)       fl_size <= 2'd1;        // W25Q16, 2 MB
                    else if (frx[23:16] == 8'hEF && (frx[15:8] == 8'h40 || frx[15:8] == 8'h70) &&
                        frx[7:0] == 8'h16)       fl_size <= 2'd2;        // W25Q32, 4 MB
                    else                         fl_size <= 2'd0;        // unknown: no writes
                    id_done <= 1'b1; fl_busy <= 1'b0; fst <= S_IDLE;
                end else if (fstep == 2'd0) begin
                    // write enable sent: now the sector erase or the page program command
                    fstep <= 2'd1; frbits <= 5'd0; fst <= S_CMD;
                    if (fop == OP_ERASE) begin fsh <= {8'h20, fop_addr, 8'h00};   fnbits <= 6'd32; end
                    else                 begin fsh <= {8'h02, fop_addr, fop_data}; fnbits <= 6'd40; end
                end else if (fstep == 2'd2 && !frx[0]) begin
                    fl_busy <= 1'b0; fst <= S_IDLE;           // status: write finished
                end else if (fto[26]) begin
                    fl_busy <= 1'b0; fst <= S_IDLE;           // timeout: give up, do not hang
                end else begin
                    // command sent or flash still busy: read the status register (0x05)
                    fstep <= 2'd2; fsh <= {8'h05, 32'd0}; fnbits <= 6'd8; frbits <= 5'd8;
                    fst <= S_CMD;
                end
            end
        end

        S_DATA: begin               // receive bytes (sampled on the rising flash clock)
            fph <= fph + 2'd1;
            case (fph)
                2'd0: fl_clk <= 1'b0;
                2'd2: begin fl_clk <= 1'b1; fin <= {fin[6:0], fl_miso}; end
                2'd3: begin
                    fbc <= fbc + 3'd1;
                    if (fbc == 3'd7) begin
                        // complete byte in fin
                        fbytes <= fbytes + 15'd1;
                        if (!fmode_wave) begin
                            fl_rbyte <= map_ret(fin);
                            fst <= S_DONE;
                        end else begin
                            // waveform: 8192 samples, 14 bit little endian in two bytes
                            if (!fbytes[0]) begin
                                lo_byte <= fin_un;
                            end else begin
                                w_data <= {fin_un[5:0], lo_byte};
                                w1_we  <= (ftarget == 2'd1);
                                w2_we  <= (ftarget == 2'd2);
                            end
                            if (fbytes == 15'd16383) fst <= S_DONE;
                        end
                    end
                end
                default: ;
            endcase
        end

        S_DONE: begin
            fl_cs_n <= 1'b1; fl_clk <= 1'b0; fl_busy <= 1'b0;
            fst <= S_IDLE;
        end

        default: fst <= S_IDLE;
        endcase

        // timeout counter for erase/program (cleared in S_IDLE)
        if (fst != S_IDLE && !fto[26]) fto <= fto + 27'd1;

        // latch start requests (after the case statement: a new request wins over clearing)
        if (regs[6'h12][0] && !r12_prev) p12 <= 1'b1;
        if (regs[6'h0D][0] && !r0d_prev) p0d <= 1'b1;
        if (regs[6'h11][0] && !r11_prev) p11 <= 1'b1;
        if (regs[6'h13][0] && !r13_prev) p13 <= 1'b1;

        // advance the write address after every written sample
        if (w1_we || w2_we) w_addr <= w_addr + 13'd1;
    end

    // ---------------------------------------------------------------------------------
    // Wave RAMs channel 1 and 2 (8192 x 14 bit M9K blocks, initialised with a sine until
    // the firmware loads the selected waveform)
    // ---------------------------------------------------------------------------------
    reg [13:0] wave1 [0:8191];
    reg [13:0] wave2 [0:8191];
    initial begin
        $readmemh("sine8192.hex", wave1);
        $readmemh("sine8192.hex", wave2);
    end
    always @(posedge clk) if (w1_we) wave1[w_addr] <= w_data;
    always @(posedge clk) if (w2_we) wave2[w_addr] <= w_data;

    // ---------------------------------------------------------------------------------
    // Frequency calibration
    //   Register 0x22:0x23 = 25 * X in micro-Hz, X = reference frequency (default 10 MHz,
    //   adjustable in the hidden "OSCI" menu). 25 * X is the DDS clock of the original FPGA
    //   (250 MHz). This design runs the DDS at 12.5 * X, so the frequency constant is
    //     inc = F[0.1 Hz] * K >> 16,   K = round(200000 * 2^64 / R)
    //   (R = 2.5e14 gives K = 0x3_6F9B_FB3B). K is computed by a sequential restoring
    //   division after every write to 0x22/0x23. Implausible values (outside approx. +-2 %, or
    //   0 before the first write) select the default constant. The counter gate times
    //   (registers 0x24..0x27 = 5X / 50X / 500X) follow X anyway.
    // ---------------------------------------------------------------------------------
    localparam [34:0] K_DEF  = 35'h3_6F9B_FB3B;
    localparam [17:0] N_HI   = 18'd200_000;           // dividend = N_HI * 2^64
    reg  [47:0] kc_r   = 48'd0;                       // divisor R
    reg  [48:0] kc_rem = 49'd0;                       // partial remainder
    reg  [34:0] kc_q   = 35'd0;                       // quotient
    reg  [6:0]  kc_i   = 7'd0;                        // bit index 81..0
    reg  [1:0]  kc_st  = 2'd0;                        // 0 idle, 1 divide, 2 rounding, 3 apply
    reg         kc_pend = 1'b1, kc_rb = 1'b0;         // pending request, rounding bit
    reg  [34:0] kfreq  = K_DEF;                       // constant used by all f2inc instances
    wire [63:0] kc_in  = {regs[6'h22], regs[6'h23]};
    // Plausible: R[63:48] = 0 and R[47:40] = 0xDF..0xE7 (approx. 2.452e14 .. 2.551e14,
    // X = 9.81 .. 10.2 MHz)
    wire        kc_ok  = (kc_in[63:48] == 16'd0) && (kc_in[47:40] >= 8'hDF) && (kc_in[47:40] <= 8'hE7);
    reg  [17:0] kc_n   = 18'd0;                       // dividend bits, MSB first, followed by 64 zeros
    wire        kc_nb  = kc_n[17];
    wire [49:0] kc_sh  = {kc_rem, kc_nb};
    wire        kc_ge  = (kc_sh >= {2'b00, kc_r});
    always @(posedge clk) begin
        if (kc_wr) kc_pend <= 1'b1;
        case (kc_st)
        2'd0: if (kc_pend && !kc_wr) begin
                  kc_pend <= 1'b0;
                  if (!kc_ok) kfreq <= K_DEF;
                  else begin kc_r <= kc_in[47:0]; kc_rem <= 49'd0; kc_q <= 35'd0; kc_n <= N_HI; kc_i <= 7'd81; kc_st <= 2'd1; end
              end
        2'd1: begin
                  kc_rem <= kc_ge ? kc_sh[48:0] - {1'b0, kc_r} : kc_sh[48:0];
                  kc_q   <= {kc_q[33:0], kc_ge};       // quotient < 2^35, higher bits are 0
                  kc_n   <= {kc_n[16:0], 1'b0};
                  if (kc_i == 7'd0) kc_st <= 2'd2; else kc_i <= kc_i - 7'd1;
              end
        2'd2: begin kc_rb <= ({kc_rem, 1'b0} >= {2'b00, kc_r}); kc_st <= 2'd3; end   // remainder >= R/2
        2'd3: begin kfreq <= kc_q + {34'd0, kc_rb}; kc_st <= 2'd0; end
        endcase
    end

    // ---------------------------------------------------------------------------------
    // Channels
    // ---------------------------------------------------------------------------------
    wire [47:0] ph1, ph2;
    wire        ttl1, ttl2, ttl1_on, ttl2_on, ttl1_early;
    // Uplink slave: a rising edge at Sync IN reloads both channels with their start phase
    // (same effect as a write to register 0x2F)
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  [2:0]  sin_s = 3'b000;
    reg         ul_sync = 1'b0;
    always @(posedge clk) begin
        sin_s   <= {sin_s[1:0], sync_in};
        ul_sync <= (regs[6'h05][6:5] == 2'b11) && sin_s[1] && !sin_s[2];
    end
    // Wave RAM read ports, addressed by the upper 13 phase bits (registered for timing)
    reg  [13:0] w1_q = 14'd0, w2_q = 14'd0;
    always @(posedge clk) w1_q <= wave1[ph1[47:35]];
    always @(posedge clk) w2_q <= wave2[ph2[47:35]];

    // Channel 1: all modulation inputs connected (CH1 is the modulated channel)
    dds_ch u_ch1 (
        .clk (clk), .run (locked),
        .freq ({regs[6'h06], regs[6'h07]}), .kfreq (kfreq),
        .ph_load (ph_sync | ul_sync), .ph_val (regs[6'h0A][19:0]),
        .mode (regs[6'h04][2:0]), .duty (regs[6'h30][17:0]),
        .r_gain (regs[6'h32]), .r_width (regs[6'h34]),
        .phase (ph1), .wq (w1_q), .dac (dac_d), .ttl (ttl1), .ttl_on (ttl1_on), .ttl_early (ttl1_early),
        .mod_mode (regs[6'h21][6:0]), .mod_sig (dac2_d), .am_depth (regs[6'h2E][11:0]),
        .mod_freq ({regs[6'h1E], regs[6'h20]}), .pm_dev (regs[6'h36][17:0]),
        .bsrc_n (regs[6'h19][23:0]), .manu (regs[6'h18][0]), .ext_ac (xac_s[1]), .ext_dc (xdc_s[1]),
        .ext_mod (regs[6'h2D][11:0]), .pw (regs[6'h1D])
    );
    // Channel 2: modulation inputs tied to constants (synthesis removes the modulation logic,
    // the output latency stays identical to CH1)
    dds_ch u_ch2 (
        .clk (clk), .run (locked),
        .freq ({regs[6'h08], regs[6'h09]}), .kfreq (kfreq),
        .ph_load (ph_sync | ul_sync), .ph_val (regs[6'h0B][19:0]),
        .mode (regs[6'h04][5:3]), .duty (regs[6'h31][17:0]),
        .r_gain (regs[6'h33]), .r_width (regs[6'h35]),
        .phase (ph2), .wq (w2_q), .dac (dac2_d), .ttl (ttl2), .ttl_on (ttl2_on), .ttl_early (),
        .mod_mode (7'd0), .mod_sig (14'h2000), .am_depth (12'd0),
        .mod_freq (64'd0), .pm_dev (18'd0),
        .bsrc_n (24'd0), .manu (1'b0), .ext_ac (1'b0), .ext_dc (1'b0),
        .ext_mod (12'h800), .pw (32'd0)
    );

    // CH1 DAC clock: inverted system clock from a DDR output register (data changes with the
    // rising system clock, the DAC latches in the middle of the data eye)
    altddio_out #(
        .intended_device_family ("Cyclone IV E"), .width (1), .lpm_type ("altddio_out")
    ) u_dacclk (
        .datain_h (1'b0), .datain_l (1'b1), .outclock (clk), .dataout (dac_clk),
        .aclr (1'b0), .aset (1'b0), .oe (1'b1), .outclocken (1'b1),
        .sclr (1'b0), .sset (1'b0), .oe_out ()
    );
    // CH2 DAC clock: separate, phase-shifted PLL output so that no clock edge coincides with
    // a data transition (spikes on steep edges, clock pin 129 is next to the MSB pin 128)
    altddio_out #(
        .intended_device_family ("Cyclone IV E"), .width (1), .lpm_type ("altddio_out")
    ) u_dacclk2 (
        .datain_h (1'b1), .datain_l (1'b0), .outclock (pll_clk[1]), .dataout (dac2_clk),
        .aclr (1'b0), .aset (1'b0), .oe (1'b1), .outclocken (1'b1),
        .sclr (1'b0), .sset (1'b0), .oe_out ()
    );

    // ---------------------------------------------------------------------------------
    // Relays, TTL / sync outputs, MCP4822
    // ---------------------------------------------------------------------------------
    // Output range relays, register 0x05: bit 3/2 = CH1 large/small, bit 1/0 = CH2 large/small
    always @(posedge clk) begin
        rly_ch1_big   <= regs[6'h05][3];
        rly_ch1_small <= regs[6'h05][2];
        rly_ch2_big   <= regs[6'h05][1];
        rly_ch2_small <= regs[6'h05][0];
    end

    // TTL outputs: 0 deg and inverted (output registers packed into the I/O elements).
    // The inverted outputs are forced low when the channel is off (mode 7).
    always @(posedge clk) begin
        ttl_a <= ttl1;  ttl_b <= ttl1_on & ~ttl1;
        ttl_c <= ttl2;  ttl_d <= ttl2_on & ~ttl2;
        sync_out <= (regs[6'h05][6:5] == 2'b00) ? ttl1_early : ttl1;   // master: without output delay
    end

    // MCP4822: /LDAC tied low, outputs update at the end of each SPI word
    assign mcp_ldac_n  = 1'b0;
    assign mcp2_ldac_n = 1'b0;
    mcp_drv u_mcp1 (.clk10 (clk10), .amp (regs[6'h2B][11:0]), .off (regs[6'h29][11:0]),
                    .cs_n (mcp_cs_n), .sck (mcp_sck), .sdi (mcp_sdi));
    mcp_drv #(.SWAP (1)) u_mcp2 (.clk10 (clk10), .amp (regs[6'h2C][11:0]), .off (regs[6'h2A][11:0]),
                    .cs_n (mcp2_cs_n), .sck (mcp2_sck), .sdi (mcp2_sdi));

endmodule


// =====================================================================================
// dds_ch - one DDS channel
// =====================================================================================
// Frequency to phase increment conversion, 48-bit phase accumulator, modulation (CH1 only),
// waveform generation and the output pipeline to the DAC.
//
// Output latency from the phase register to the DAC register (identical with and without
// modulation): table waveforms 9 clocks, trapezoid 11, square/CMOS/pulse 12.
// =====================================================================================
module dds_ch (
    input  wire        clk,
    input  wire        run,       // accumulator runs (PLL locked)
    input  wire [63:0] freq,      // frequency in 0.1 Hz units (registers 0x06:0x07 / 0x08:0x09)
    input  wire [34:0] kfreq,     // frequency constant (calibration, default 0x3_6F9B_FB3B)
    input  wire        ph_load,   // pulse: load the phase accumulator with ph_val
    input  wire [19:0] ph_val,    // start phase, 20 bit, 2^20 = 360 deg (registers 0x0A / 0x0B)
    input  wire [2:0]  mode,      // 0 table, 1 square/rectangle, 2 trapezoid, 3 CMOS, 4 Adj-Pulse, 7 DC/off
    input  wire [17:0] duty,      // duty cycle, 2^17 = 100 % (registers 0x30 / 0x31)
    input  wire [31:0] r_gain,    // trapezoid: (16383 / rise) << 14 | 16383 / fall (registers 0x32 / 0x33)
    input  wire [31:0] r_width,   // trapezoid: rise << 14 | fall, in 1/16384 of a period (registers 0x34 / 0x35)
    output reg  [47:0] phase = 48'd0,
    output wire        ttl,       // TTL sync signal 0 deg (latency matched to the DAC path)
    output wire        ttl_on,    // channel not off (mode 7) -> inverted TTL output active
    output wire        ttl_early, // like ttl, but without latency matching (1 clock after the phase)
    input  wire [13:0] wq,        // wave RAM output for phase[47:35]
    output reg  [13:0] dac = 14'h2000,
    // Modulation (only used on CH1; constant on CH2 -> removed by synthesis, latency unchanged)
    input  wire [6:0]  mod_mode,  // register 0x21: b0 PSK, b1 FSK, b2 ASK, b3 AM, b4 external source, b5 FM, b6 PM
    input  wire [13:0] mod_sig,   // internal modulation signal = CH2 DAC value (centre 0x2000)
    input  wire [11:0] am_depth,  // register 0x2E: AM depth, firmware writes depth[0.1 %] * 2047 / 2000
    input  wire [63:0] mod_freq,  // {reg 0x1E, reg 0x20}: FM deviation or FSK hop frequency in 0.1 Hz
    input  wire [17:0] pm_dev,    // register 0x36: PM deviation ("BIAS" in the menu), 2^17 = 360 deg
    input  wire [23:0] bsrc_n,    // register 0x19: [19:0] burst count, [23:20] source + 1 (0 = none)
    input  wire        manu,      // register 0x18 bit 0: MANU key (pressed = 0), burst trigger 0 -> 1
    input  wire        ext_ac,    // Ext.(AC) = Counter input (synchronised)
    input  wire        ext_dc,    // Ext.(DC) = Trig IN (synchronised)
    input  wire [11:0] ext_mod,   // register 0x2D: VCO-IN sample from the STM32 ADC (0..4095, centre 0x800)
    input  wire [31:0] pw         // register 0x1D: Adj-Pulse width in 4 ns units (CH1 only, firmware: width_ns / 4)
);
    // ---------------------------------------------------------------------------------
    // Phase increments: carrier and modulation frequency (FM deviation / FSK hop frequency)
    // ---------------------------------------------------------------------------------
    wire [47:0] inc, inc2;
    reg  [13:0] sq_out = 14'd0, cm_out = 14'h2000;   // outputs of the edge interpolation (below)
    f2inc u_f2i  (.clk (clk), .freq (freq),     .k (kfreq), .inc (inc));
    f2inc u_f2i2 (.clk (clk), .freq (mod_freq), .k (kfreq), .inc (inc2));

    // ---------------------------------------------------------------------------------
    // Modulation signal, signed, approx. -16383..+16383 (= -1..+1)
    // ---------------------------------------------------------------------------------
    reg  signed [15:0] m_s = 16'sd0;
    reg  [6:0]         mm  = 7'd0;
    always @(posedge clk) begin
        // Register 0x21 bit 4 together with AM/FM/PM selects the external source Ext.(VCO-IN):
        // (ADC - 0x800) * 8, otherwise CH2
        if (mod_mode[4] && (mod_mode[3] || mod_mode[5] || mod_mode[6]))
            m_s <= $signed({ext_mod - 12'h800, 4'b0000}) >>> 1;
        else
            // 2 * CH2 - 16383: centre 8191.5 like the symmetric sine table -> no DC error
            // (a DC error would show up as a constant FM frequency offset)
            m_s <= $signed({1'b0, mod_sig, 1'b0}) - 16'sd16383;
        mm  <= mod_mode;
    end
    wire m_hi = ~m_s[15];                     // CH2 in the upper half

    // ---------------------------------------------------------------------------------
    // Keying source (FSK/ASK/PSK) and burst trigger, register 0x19 bits 23:20 = source + 1:
    //   1 = CH2 (upper half), 2 = Ext.(AC), 3 = MANU (register 0x18), 4 = Ext.(DC)
    // BURST is active when register 0x21 has no mode bit set (firmware writes 0x10) and a
    // source is selected.
    // ---------------------------------------------------------------------------------
    reg  [3:0]  src = 4'd0;
    reg  [19:0] b_n = 20'd0;
    reg         t_lvl = 1'b0, t_prev = 1'b0, t_inv = 1'b0, b_en = 1'b0;
    always @(posedge clk) begin
        src <= bsrc_n[23:20];
        b_n <= bsrc_n[19:0];
        case (src)
            4'd2:    t_lvl <= ext_ac;
            4'd3:    t_lvl <= manu;
            4'd4:    t_lvl <= ext_dc;
            default: t_lvl <= m_hi;
        endcase
        t_inv  <= (src == 4'd3);              // MANU: key pressed (0) = keyed
        t_prev <= t_lvl;
        b_en   <= (src != 4'd0) && ((mm & 7'b110_1111) == 7'd0);
    end
    wire key   = t_lvl ^ t_inv;               // 1 = hop frequency / carrier on / 180 deg
    wire b_trg = t_lvl & ~t_prev;             // burst: rising edge of the source

    // ---------------------------------------------------------------------------------
    // FM: inc_eff = inc + inc2 * m / 16384 (m = 2 * CH2 - 16383). The lower 17 bits of inc2
    // (< 0.0001 Hz) are dropped so that each partial product fits into one 18x18 multiplier
    // at 125 MHz. FSK switches to the hop frequency while keyed.
    // ---------------------------------------------------------------------------------
    reg  signed [15:0] m_f = 16'sd0;
    reg  [16:0]        i2_hi = 17'd0;
    reg  [12:0]        i2_lo = 13'd0;
    reg  signed [33:0] fm_hi = 34'sd0;
    reg  signed [29:0] fm_lo = 30'sd0;
    reg  signed [47:0] fm_add = 48'sd0;
    reg  [47:0]        inc_eff = 48'd0;
    always @(posedge clk) begin
        m_f    <= m_s;
        i2_hi  <= inc2[46:30];
        i2_lo  <= inc2[29:17];
        fm_hi  <= $signed({1'b0, i2_hi}) * m_f;
        fm_lo  <= $signed({1'b0, i2_lo}) * m_f;
        fm_add <= ({{14{fm_hi[33]}}, fm_hi} <<< 16) + ({{18{fm_lo[29]}}, fm_lo} <<< 3);
        if (mm[5])                inc_eff <= inc + fm_add;           // FM
        else if (mm[1] && key)    inc_eff <= inc2;                   // FSK: hop frequency
        else                      inc_eff <= inc;
    end

    // ---------------------------------------------------------------------------------
    // PM / PSK / burst: phase offset added to the accumulator for the output phase
    // ---------------------------------------------------------------------------------
    reg  signed [34:0] pm_prod = 35'sd0;
    reg  [47:0]        pm_off  = 48'd0;
    always @(posedge clk) begin
        pm_prod <= $signed({1'b0, pm_dev}) * m_s;
        if (mm[6])                pm_off <= {{13{pm_prod[34]}}, pm_prod} << 17;   // PM: +-deviation
        else if (mm[0] && key)    pm_off <= 48'h8000_0000_0000;      // PSK: 180 deg
        else if (b_en)            pm_off <= {ph_val, 28'd0};         // burst: start phase
        else                      pm_off <= 48'd0;
    end
    wire pm_any = mm[6] | mm[0] | b_en;

    // ---------------------------------------------------------------------------------
    // Phase accumulator
    //   Burst: while idle the accumulator holds 2^48-1 (end of a period, the output shows the
    //   value at the start phase). A trigger starts counting: the first overflow begins
    //   period 1, the (N+1)th overflow ends the burst after N complete periods. Count 0 =
    //   no output (firmware 1.8.0 first writes count 0 when MANU is selected and only the OK
    //   key writes N).
    //   Timing: the end decision only feeds the flip-flop b_run; the accumulator runs one more
    //   clock (value = start of period N+1), this value is replaced by the idle value in the
    //   output phase (b_hold), afterwards the accumulator holds 2^48-1 again.
    // ---------------------------------------------------------------------------------
    reg [47:0] acc = 48'd0;
    reg        acc_wrap = 1'b0;
    reg        b_run = 1'b0, b_wr = 1'b0;
    reg [19:0] b_cnt = 20'd0;
    wire [48:0] acc_sum = {1'b0, acc} + {1'b0, inc_eff};
    wire        b_last  = (b_cnt >= b_n);   // ">=": a count reduced during a burst also ends it
    wire        b_hold  = b_en & ~b_run;      // burst idle
    always @(posedge clk)
        if (b_en) begin
            acc_wrap <= 1'b0;
            b_wr     <= 1'b0;
            // count one clock later (timing); overflows are >= 2 clocks apart (f < 62.5 MHz)
            if (b_wr) b_cnt <= b_cnt + 20'd1;
            if (!b_run) begin
                acc <= 48'hFFFF_FFFF_FFFF;
                if (b_trg) begin b_run <= 1'b1; b_cnt <= 20'd0; end
            end else begin
                acc  <= acc_sum[47:0];
                b_wr <= acc_sum[48];
                if (acc_sum[48] && b_last) b_run <= 1'b0;
            end
        end else begin
            b_run <= 1'b0;
            b_wr  <= 1'b0;
            if (ph_load)  begin acc <= {ph_val, 28'd0}; acc_wrap <= 1'b0; end
            else if (run) {acc_wrap, acc} <= acc_sum;
        end

    // Output phase = accumulator + PM/PSK/burst offset; ph_wrap = overflow (rising edge of a
    // square wave, used by the edge interpolation)
    reg  ph_wrap = 1'b0;
    reg  [47:0] ph_idle = 48'hFFFF_FFFF_FFFF;     // burst idle: start phase - 1 LSB
    wire [47:0] ph_next = acc + pm_off;
    always @(posedge clk) begin
        ph_idle <= {ph_val, 28'd0} - 48'd1;
        phase   <= b_hold ? ph_idle : ph_next;
        if (b_hold)      ph_wrap <= 1'b0;
        else if (pm_any) ph_wrap <= phase[47] && !ph_next[47];   // step < 180 deg: MSB 1 -> 0 = overflow
        else             ph_wrap <= acc_wrap;
    end

    // ---------------------------------------------------------------------------------
    // Waveforms: trapezoid and output selection
    // ---------------------------------------------------------------------------------
    reg [2:0]  mode_r = 3'd0;
    reg [17:0] duty_r = 18'h10000;
    reg [13:0] rise_w = 14'd7, fall_w = 14'd7, rise_g = 14'd2340, fall_g = 14'd2340;
    reg [13:0] p14_a = 14'd0, d14 = 14'h2000;
    reg [1:0]  tz_seg = 2'd0;          // 0 rising, 1 high, 2 falling, 3 low
    reg [13:0] tz_x = 14'd0, tz_g = 14'd0;
    reg [27:0] tz_prod = 28'd0;
    reg [1:0]  tz_seg2 = 2'd0;
    reg [13:0] tz_out = 14'd0;
    reg [14:0] tz_fe = 15'd0;
    reg [13:0] wq_r = 14'h2000;        // register stage after the wave RAM (125 MHz)
    reg [13:0] dac_pre = 14'h2000;
    always @(posedge clk) begin
        wq_r   <= wq;
        mode_r <= mode;
        duty_r <= duty;
        rise_w <= (r_width[27:14] == 14'd0) ? 14'd1 : r_width[27:14];
        fall_w <= (r_width[13:0]  == 14'd0) ? 14'd1 : r_width[13:0];
        rise_g <= r_gain[27:14];
        fall_g <= r_gain[13:0];
        d14    <= duty_r[16:3];
        tz_fe  <= {1'b0, duty_r[16:3]} + {1'b0, fall_w};

        // (square/CMOS/pulse are generated by the edge interpolation further below)

        // Trapezoid: segment selection, multiplication (position * slope), limiting
        p14_a <= phase[47:34];
        if (p14_a < rise_w) begin
            tz_seg <= 2'd0; tz_x <= p14_a; tz_g <= rise_g;
        end else if (p14_a < d14) begin
            tz_seg <= 2'd1; tz_x <= 14'd0; tz_g <= 14'd0;
        end else if ({1'b0, p14_a} < tz_fe) begin
            tz_seg <= 2'd2; tz_x <= p14_a - d14; tz_g <= fall_g;
        end else begin
            tz_seg <= 2'd3; tz_x <= 14'd0; tz_g <= 14'd0;
        end
        tz_prod <= tz_x * tz_g;
        tz_seg2 <= tz_seg;
        case (tz_seg2)
            2'd0: tz_out <= (tz_prod[27:14] != 14'd0) ? 14'h3FFF : tz_prod[13:0];
            2'd1: tz_out <= 14'h3FFF;
            2'd2: tz_out <= (tz_prod[27:14] != 14'd0) ? 14'd0 : 14'h3FFF - tz_prod[13:0];
            default: tz_out <= 14'd0;
        endcase

        case (mode_r)
            3'd1:       dac_pre <= sq_out;      // square with edge interpolation
            // CMOS / pulse: unipolar from the centre to full scale; the firmware writes twice
            // the amplitude for these modes
            3'd3, 3'd4: dac_pre <= cm_out;
            3'd2:       dac_pre <= tz_out;
            3'd7:       dac_pre <= 14'h2000;    // DC / channel off: centre (0 V before the offset)
            default:    dac_pre <= wq_r;
        endcase
    end

    // ---------------------------------------------------------------------------------
    // High threshold for square/CMOS/pulse as a 48-bit phase (2^48 = always high):
    //   square/CMOS: duty cycle (register 0x30/0x31, 2^17 = 100 %)
    //   Adj-Pulse (mode 4, CH1 only): fixed width pw * 4 ns -> threshold = pw * inc / 2,
    //   computed sequentially (shift-and-add, 32 steps MSB first) whenever pw or inc
    //   changes, saturating at 2^48. A 17-bit duty value would be far too coarse for this
    //   (at 10 Hz one step would be 760 ns).
    // ---------------------------------------------------------------------------------
    reg [31:0] pw_last = 32'd0, pw_sh = 32'd0;
    reg [47:0] pw_inc  = 48'd0;
    reg [50:0] pw_acc  = 51'd0;
    reg        pw_sat  = 1'b0, pw_run = 1'b0;
    reg [5:0]  pw_i    = 6'd0;
    reg [48:0] pw_thr  = 49'd0;
    wire [50:0] pw_nx  = {pw_acc[49:0], 1'b0} + (pw_sh[31] ? {3'd0, pw_inc} : 51'd0);
    always @(posedge clk) begin
        if (!pw_run) begin
            if ((pw != pw_last) || (inc != pw_inc)) begin
                pw_last <= pw; pw_inc <= inc; pw_sh <= pw;
                pw_acc <= 51'd0; pw_sat <= 1'b0; pw_i <= 6'd0; pw_run <= 1'b1;
            end
        end else if (!pw_i[5]) begin                      // 32 steps
            pw_sh  <= {pw_sh[30:0], 1'b0};
            pw_acc <= pw_nx;
            pw_i   <= pw_i + 6'd1;
            // check the overflow on the register (without overflow pw_nx stays < 2^51)
            if (pw_acc[50:49] != 2'b00) pw_sat <= 1'b1;
        end else begin                                     // finish
            pw_run <= 1'b0;
            pw_thr <= (pw_sat || (pw_acc[50:49] != 2'b00)) ? 49'h1_0000_0000_0000 : {1'b0, pw_acc[48:1]};
        end
    end
    reg  [48:0] thr_r = 49'h0_8000_0000_0000;
    always @(posedge clk) thr_r <= (mode_r == 3'd4) ? pw_thr : {duty_r, 31'd0};
    wire        hi_cmp = ({1'b0, phase} < thr_r);

    // ---------------------------------------------------------------------------------
    // TTL sync signal: square/trapezoid/CMOS/pulse follow the duty cycle (or pulse width),
    // all other waveforms are high while the phase is < 180 deg (rising edge at the upward
    // zero crossing of the sine). Mode 7 (DC / off): low.
    // Delay up to the output register in the top level matches the DAC value:
    //   table 9, trapezoid 11, square/CMOS/pulse 12 clocks after the phase.
    // ---------------------------------------------------------------------------------
    reg        ttl_raw = 1'b0;
    reg [9:0]  ttl_sr  = 10'd0;
    wire       ttl_duty = (mode_r == 3'd1) || (mode_r == 3'd2) || (mode_r == 3'd3) || (mode_r == 3'd4);
    always @(posedge clk) begin
        ttl_raw <= (mode_r == 3'd7) ? 1'b0 : ttl_duty ? hi_cmp : ~phase[47];
        ttl_sr  <= {ttl_sr[8:0], ttl_raw};
    end
    assign ttl    = (mode_r == 3'd2) ? ttl_sr[8] : ttl_duty ? ttl_sr[9] : ttl_sr[6];
    assign ttl_on = (mode_r != 3'd7);
    assign ttl_early = ttl_raw;

    // ---------------------------------------------------------------------------------
    // AM / ASK on the output value (fixed latency of 6 clocks, also without modulation)
    //   AM:  out = c * (1 + d * m) / (1 + d), d = depth (0..1), the peak stays = amplitude
    //   ASK: keyed -> carrier, otherwise centre (off)
    // ---------------------------------------------------------------------------------
    reg  [12:0] am_d = 13'd0;                 // depth in 1/4096
    always @(posedge clk) am_d <= {am_depth, 1'b0};

    // g = 2^24 / (4096 + d), sequential restoring division whenever the depth changes
    reg [12:0] g_d_last = 13'h1FFF;
    reg [13:0] g_div = 14'd4096;
    reg [24:0] g_num = 25'd0;
    reg [13:0] g_rem = 14'd0;
    reg [12:0] g_q = 13'd0, g_val = 13'd4096;
    reg [4:0]  g_i = 5'd0;
    reg        g_run = 1'b0;
    wire [13:0] g_sh = {g_rem[12:0], g_num[g_i]};
    wire        g_ge = (g_sh >= g_div);
    always @(posedge clk) begin
        if (!g_run) begin
            if (am_d != g_d_last) begin
                g_d_last <= am_d; g_div <= 14'd4096 + {1'b0, am_d};
                g_num <= 25'h100_0000; g_rem <= 14'd0; g_q <= 13'd0; g_i <= 5'd24; g_run <= 1'b1;
            end
        end else begin
            g_rem <= g_ge ? g_sh - g_div : g_sh;
            g_q   <= {g_q[11:0], g_ge};
            if (g_i == 5'd0) begin g_run <= 1'b0; g_val <= {g_q[11:0], g_ge}; end
            else g_i <= g_i - 5'd1;
        end
    end

    // Pipeline: dp1..dp5 carry the unmodulated value, c1..c4 the signed carrier,
    // env = 1 + d * m (4096 = 1.0), eg = env * g, o5 = carrier * envelope
    reg  [13:0]        dp1 = 14'h2000, dp2 = 14'h2000, dp3 = 14'h2000, dp4 = 14'h2000, dp5 = 14'h2000;
    reg  signed [14:0] c1 = 0, c2 = 0, c3 = 0, c4 = 0;
    reg  signed [29:0] dm = 0;
    reg  signed [14:0] env = 15'sd4096;
    reg  signed [27:0] eg = 0;
    reg  signed [14:0] egn = 15'sd4096;
    reg  signed [29:0] o5 = 0;
    reg  [4:0]         hi_d = 5'd0;           // key delayed to match the pipeline
    always @(posedge clk) begin
        dp1 <= dac_pre; dp2 <= dp1; dp3 <= dp2; dp4 <= dp3; dp5 <= dp4;
        hi_d <= {hi_d[3:0], key};
        c1  <= $signed({1'b0, dac_pre}) - 15'sd8192;
        dm  <= $signed({1'b0, am_d}) * m_s;
        c2  <= c1;
        env <= 15'sd4096 + (dm >>> 14);
        c3  <= c2;
        eg  <= env * $signed({1'b0, g_val});
        c4  <= c3;
        egn <= eg >>> 12;
        o5  <= c4 * egn;
        if (mm[3])                      dac <= 14'h2000 + o5[25:12];   // AM
        else if (mm[2] && !hi_d[4])     dac <= 14'h2000;               // ASK, not keyed: off
        else                            dac <= dp5;
    end

    // ---------------------------------------------------------------------------------
    // Edge interpolation for square / CMOS / pulse
    //   If an edge falls between two samples, the sample shows the fraction of the clock
    //   interval during which the signal was high (area average). The DAC's reconstruction
    //   filter turns this into an edge at the correct sub-sample position, so the edge jitter
    //   drops from one clock (8 ns) to well below 1 ns.
    //     fraction = x / inc, x = phase after the edge (rising) or
    //                         threshold - previous phase (falling)
    //   1/inc is computed sequentially whenever the frequency changes:
    //     s = number of leading zeros of inc, rec = 2^26 / inc_norm[47:35]
    // ---------------------------------------------------------------------------------
    reg [47:0] r_inc_last = 48'd0, r_t = 48'd0;
    reg [5:0]  r_s = 6'd0, r_s_new = 6'd0;
    reg [14:0] r_rec = 15'd8192;
    reg [12:0] r_div = 13'd4096;
    reg [26:0] r_num = 27'd0;
    reg [14:0] r_q = 15'd0;
    reg [13:0] r_rem = 14'd0;
    reg [4:0]  r_i = 5'd0;
    reg [1:0]  r_st = 2'd0;
    always @(posedge clk) begin
        case (r_st)
        2'd0: if (inc != r_inc_last) begin            // new frequency: normalise
                  r_inc_last <= inc; r_t <= inc; r_s_new <= 6'd0; r_st <= 2'd1;
              end
        2'd1: if (r_t[47] || r_s_new == 6'd47 || r_t == 48'd0) begin
                  r_div <= r_t[47:35]; r_num <= 27'h400_0000; r_q <= 15'd0;
                  r_rem <= 14'd0; r_i <= 5'd26; r_st <= 2'd2;
              end else begin
                  r_t <= r_t << 1; r_s_new <= r_s_new + 6'd1;
              end
        2'd2: begin                                    // division 2^26 / r_div, bit by bit
                  if ({r_rem[12:0], r_num[r_i]} >= {1'b0, r_div}) begin
                      r_rem <= {r_rem[12:0], r_num[r_i]} - {1'b0, r_div};
                      r_q   <= {r_q[13:0], 1'b1};
                  end else begin
                      r_rem <= {r_rem[12:0], r_num[r_i]};
                      r_q   <= {r_q[13:0], 1'b0};
                  end
                  if (r_i == 5'd0) r_st <= 2'd3;
                  else r_i <= r_i - 5'd1;
              end
        2'd3: begin
                  r_rec <= (r_div == 13'd0) ? 15'd0 : r_q;
                  r_s   <= r_s_new;
                  r_st  <= 2'd0;
              end
        endcase
    end

    // Stage 1: edge detection
    reg [47:0] ph_prev = 48'd0;
    reg        e_hi_now = 1'b0, e_hi_prev = 1'b0, e_wrap = 1'b0, e_ok = 1'b0;
    reg [47:0] e_xr = 48'd0, e_xf = 48'd0;
    always @(posedge clk) begin
        ph_prev   <= phase;
        e_hi_now  <= hi_cmp;
        e_hi_prev <= e_hi_now;                 // = comparison of the previous phase
        e_wrap    <= ph_wrap;
        e_xr      <= phase;
        e_xf      <= thr_r[47:0] - ph_prev;
        e_ok      <= (thr_r != 49'd0) && !thr_r[48] && !ph_load;
    end
    // Stage 2: type of edge, select x
    reg [1:0]  k2 = 2'd0;              // 0 none, 1 rising, 2 falling
    reg        h2 = 1'b0;
    reg [47:0] x2 = 48'd0;
    always @(posedge clk) begin
        h2 <= e_hi_now;
        x2 <= e_wrap ? e_xr : e_xf;
        if (e_ok && e_wrap && e_hi_now && !e_hi_prev)        k2 <= 2'd1;
        else if (e_ok && !e_wrap && e_hi_prev && !e_hi_now) k2 <= 2'd2;
        else                                                k2 <= 2'd0;
    end
    // Stage 3: window x << s, upper 13 bits
    wire [60:0] x2_ext = {x2, 13'd0};
    reg  [12:0] x3 = 13'd0;
    reg  [1:0]  k3 = 2'd0;
    reg         h3 = 1'b0;
    always @(posedge clk) begin
        x3 <= x2_ext[6'd60 - r_s -: 13];
        k3 <= k2; h3 <= h2;
    end
    // Stage 4: x * (2^26 / inc)
    reg [27:0] p4 = 28'd0;
    reg [1:0]  k4 = 2'd0;
    reg        h4 = 1'b0;
    always @(posedge clk) begin
        p4 <= x3 * r_rec;
        k4 <= k3; h4 <= h3;
    end
    // Stage 5: fraction 0..16383 and output values (sq_out, cm_out are declared at the top)
    wire [13:0] frac = (p4[27:26] != 2'b00) ? 14'h3FFF : p4[25:12];
    always @(posedge clk) begin
        if (k4 == 2'd0) begin
            sq_out <= h4 ? 14'h3FFF : 14'd0;
            cm_out <= h4 ? 14'h3FFF : 14'h2000;
        end else begin
            sq_out <= frac;
            cm_out <= 14'h2000 + {1'b0, frac[13:1]};
        end
    end
endmodule


// =====================================================================================
// f2inc - frequency (0.1 Hz units, 64 bit) to 48-bit phase increment at 125 MHz
//   inc = (F * k) >> 16, default k = round(2^64 / (10 * 125e6)) = 0x3_6F9B_FB3B
//   Sequential shift-and-add over the 35 bits of k; a new result every 37 clocks
//   (the firmware changes frequencies far less often than that, sweeps included).
// =====================================================================================
module f2inc (
    input  wire        clk,
    input  wire [63:0] freq,
    input  wire [34:0] k,         // inc = freq * k >> 16
    output reg  [47:0] inc = 48'd0
);
    reg [5:0]  mi = 6'd0;
    reg [79:0] macc = 80'd0, msh = 80'd0;
    always @(posedge clk) begin
        if (mi == 6'd0) begin
            msh  <= {16'd0, freq};
            macc <= 80'd0;
            mi   <= 6'd1;
        end else if (mi <= 6'd35) begin
            if (k[mi - 6'd1]) macc <= macc + msh;
            msh <= msh << 1;
            mi  <= mi + 6'd1;
        end else begin
            inc <= macc[63:16];
            mi  <= 6'd0;
        end
    end
endmodule


// =====================================================================================
// mcp_drv - MCP4822 dual 12-bit DAC driver (amplitude and offset of one channel)
//   CH1: VOUTA = offset (gain 2x), VOUTB = amplitude (gain 1x)
//   CH2: outputs swapped (SWAP = 1): VOUTA = amplitude, VOUTB = offset
//   The amplitude output drives the REFI/O pin of the DAC-1412 through a 300/499 ohm divider,
//   i.e. it sets the full-scale current of the waveform DAC. The two outputs are written
//   alternately, one 16-bit word about every 100 us, SCK = 5 MHz (clk10 / 2).
// =====================================================================================
module mcp_drv #(
    parameter SWAP = 0              // 1: VOUTA = amplitude, VOUTB = offset
) (
    input  wire        clk10,
    input  wire [11:0] amp,
    input  wire [11:0] off,
    output reg         cs_n = 1'b1,
    output reg         sck  = 1'b0,
    output reg         sdi  = 1'b0
);
    // Values come from the 125 MHz domain: sample twice and only take over stable values
    reg [11:0] amp_s1 = 12'd0, amp_s2 = 12'd0, amp_v = 12'd0;
    reg [11:0] off_s1 = 12'h7FF, off_s2 = 12'h7FF, off_v = 12'h7FF;
    always @(posedge clk10) begin
        amp_s1 <= amp; amp_s2 <= amp_s1;
        off_s1 <= off; off_s2 <= off_s1;
        if (amp_s1 == amp_s2) amp_v <= amp_s2;
        if (off_s1 == off_s2) off_v <= off_s2;
    end
    // MCP4822 command word: [15] A/B, [14] don't care, [13] /GA (0 = 2x, 1 = 1x), [12] /SHDN,
    // [11:0] data. Offset with gain 2x (/GA = 0), amplitude with gain 1x (/GA = 1).
    wire [15:0] CMD_A = SWAP ? {1'b0, 1'b0, 1'b1, 1'b1, amp_v} : {1'b0, 1'b0, 1'b0, 1'b1, off_v};
    wire [15:0] CMD_B = SWAP ? {1'b1, 1'b0, 1'b0, 1'b1, off_v} : {1'b1, 1'b0, 1'b1, 1'b1, amp_v};
    reg [9:0]  wait_c = 10'd0;
    reg [5:0]  step   = 6'd0;
    reg        sel    = 1'b0;
    reg [15:0] shift  = 16'd0;
    always @(posedge clk10) begin
        if (step == 6'd0) begin
            // pause of 1024 clk10 cycles between two words
            cs_n <= 1'b1; sck <= 1'b0;
            wait_c <= wait_c + 10'd1;
            if (wait_c == 10'h3FF) begin
                shift <= sel ? CMD_B : CMD_A;
                step  <= 6'd1;
            end
        end else if (step == 6'd1) begin
            cs_n <= 1'b0; sdi <= shift[15]; step <= 6'd2;
        end else if (step <= 6'd33) begin
            // 16 bits, data changes on the falling SCK edge, MCP4822 samples on the rising edge
            if (step[0] == 1'b0) sck <= 1'b1;
            else begin
                sck <= 1'b0;
                shift <= {shift[14:0], 1'b0};
                sdi <= shift[14];
            end
            step <= step + 6'd1;
        end else begin
            cs_n <= 1'b1; sck <= 1'b0; sel <= ~sel; step <= 6'd0;
        end
    end
endmodule
