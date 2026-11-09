// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright 2026 The FY6900_FPGA contributors
// Licensed under the CERN Open Hardware Licence Version 2 - Strongly Reciprocal (see LICENSE).
// Source location: https://github.com/Marvin-4-2/FY6900_FPGA
/*
 * FY6900 SPI sniffer (STM32 <-> FPGA) for the Raspberry Pi Pico (RP2040)
 *
 * Listens passively on the SPI bus between the STM32 front-panel MCU and the FPGA and prints
 * the register accesses as text over USB serial (115200 baud, any terminal program).
 *
 * Wiring (all Pico pins are inputs, 3.3 V levels, connect GND!):
 *   GP2  <- SCK     (STM32 PB13)
 *   GP3  <- MOSI    (STM32 PB15)  STM32 -> FPGA
 *   GP4  <- MISO    (STM32 PB14)  FPGA -> STM32
 *   GP5  <- REGSEL  (STM32 PB11)  low = address phase, high = data phase
 *   GP6  <- CS      (STM32 PB12)
 *   GND  <- GND
 *
 * Protocol (reconstructed from the stock firmware, see docs/spi-protocol.md):
 *   Write:      REGSEL=0: 16-bit address | REGSEL=1: 32-bit value (MOSI)
 *   Read:       REGSEL=0: 16-bit address | (CS pause) REGSEL=1: 32-bit value (MISO)
 *   ReadAgain:  REGSEL=1: 32-bit value (MISO) without a new address (busy polling)
 *   SPI mode 3, MSB first, sampled on the rising SCK edge.
 *
 * Output:
 *   W aa = vvvvvvvv           write access
 *   R aa -> vvvvvvvv          read access (MOSI was 0)
 *   R+ aa -> vvvvvvvv         read again without a new address
 *   ?  aa  (...)              MOSI and MISO both 0 -> write of 0 or read of 0
 *   FR aaaaaa -> bb           flash byte read (W17/0d/15/0c sequence combined into one line)
 *   Repeated identical lines are combined into "(xN)".
 *   Note: the original FPGA drives 0x000000af on MISO when idle, a write of 0 then appears as
 *   "R xx -> 000000af". With this project's FPGA a write of 0 appears as "?".
 *   Note: the 16-bit VCO-IN frames (external AM/FM/PM source) are not decoded and confuse the
 *   word alignment of this simple decoder while they are active.
 *
 * Modes (press the key in the terminal):
 *   a  all accesses (default)
 *   c  changes only: writes are printed only if the value differs from the last value
 *      written to that register, reads and flash reads are suppressed
 *   f  filter: only changes of register 0x05 bits 8/7 (WATCH05) and writes to register 0x00,
 *      with time stamp, e.g. "[  12.345 s] reg 0x05 bit 8 -> 1   (W 05 = 000001c0)"
 *
 * Build: PlatformIO (see platformio.ini), core "earlephilhower" (arduino-pico).
 */
#include <Arduino.h>
#include "hardware/pio.h"
#include "hardware/dma.h"
#include "hardware/pio_instructions.h"

static const uint PIN_SCK    = 2;
static const uint PIN_MOSI   = 3;   // PIO in_base: bit0 = MOSI, bit1 = MISO, bit2 = REGSEL, bit3 = CS
static const uint PIN_MISO   = 4;
static const uint PIN_REGSEL = 5;
static const uint PIN_CS     = 6;

// ---------------- capture: PIO samples 4 pins per SCK edge, DMA into a ring buffer --------
#define RING_BITS  15                         // 32 KB ring buffer
#define RING_WORDS (1u << (RING_BITS - 2))
static uint32_t ring[RING_WORDS] __attribute__((aligned(1 << RING_BITS)));

static PIO  pio = pio0;
static uint sm  = 0;
static int  dma_ch = -1;
static uint64_t produced_base = 0;   // words from earlier DMA runs
static uint64_t consumed = 0;

static const uint32_t DMA_COUNT = 0xFFFFFFFFu;

static void start_dma() {
    dma_channel_config c = dma_channel_get_default_config(dma_ch);
    channel_config_set_transfer_data_size(&c, DMA_SIZE_32);
    channel_config_set_read_increment(&c, false);
    channel_config_set_write_increment(&c, true);
    channel_config_set_ring(&c, true, RING_BITS);
    channel_config_set_dreq(&c, pio_get_dreq(pio, sm, false));
    dma_channel_configure(dma_ch, &c, ring, &pio->rxf[sm], DMA_COUNT, true);
}

static uint64_t produced_now() {
    uint32_t left = dma_hw->ch[dma_ch].transfer_count;
    return produced_base + (uint64_t)(DMA_COUNT - left);
}

static void setup_pio() {
    for (uint p = PIN_SCK; p <= PIN_CS; p++) {
        gpio_init(p);
        gpio_set_dir(p, GPIO_IN);
        gpio_disable_pulls(p);
    }
    // program: wait for SCK low, wait for SCK high (rising edge), sample 4 pins
    static uint16_t prog[3];
    prog[0] = pio_encode_wait_gpio(false, PIN_SCK);
    prog[1] = pio_encode_wait_gpio(true,  PIN_SCK);
    prog[2] = pio_encode_in(pio_pins, 4);
    static const pio_program_t program = { prog, 3, -1 };
    uint offset = pio_add_program(pio, &program);

    pio_sm_config c = pio_get_default_sm_config();
    sm_config_set_wrap(&c, offset, offset + 2);
    sm_config_set_in_pins(&c, PIN_MOSI);
    sm_config_set_in_shift(&c, false /* shift left */, true /* autopush */, 32);
    sm_config_set_fifo_join(&c, PIO_FIFO_JOIN_RX);
    sm_config_set_clkdiv(&c, 1.0f);
    pio_sm_init(pio, sm, offset, &c);
    pio_sm_set_enabled(pio, sm, true);
}

// ---------------- output modes ----------------
enum Mode { MODE_ALL, MODE_CHANGES, MODE_FILTER };
static Mode mode = MODE_ALL;
static const uint32_t WATCH05 = (1u << 8) | (1u << 7); // watched bits of register 0x05 (CH1/CH2 output on)
static int64_t last05 = -1;                            // last value of register 0x05 (-1 = unknown)
static int64_t last_w[64];                             // last written value per register (mode c)

static void stamp() {
    uint32_t ms = millis();
    Serial.printf("[%5lu.%03lu s] ", (unsigned long)(ms / 1000), (unsigned long)(ms % 1000));
}

static void banner() {
    switch (mode) {
    case MODE_ALL:     Serial.printf("\n== all accesses ('c' = changes only, 'f' = filter reg 0x05 bits 8/7 + reg 0x00) ==\n"); break;
    case MODE_CHANGES: Serial.printf("\n== changed writes only ('a' = all, 'f' = filter) ==\n"); break;
    case MODE_FILTER:  Serial.printf("\n== filter: reg 0x05 bits 8/7 (changes) and reg 0x00 (writes) ('a' = all, 'c' = changes) ==\n"); break;
    }
}

// registers the stock firmware reads (a frame with MOSI = 0 on these is treated as a read)
static bool is_read_reg(int a) {
    return a == 0x02 || a == 0x03 || a == 0x0C || a == 0x15 || a == 0x1B || a == 0x1F || a == 0x3A;
}

// modes c and f: returns true if the pair was handled (printed or suppressed)
static bool filter_pair(int addr, uint32_t pairs_before, uint32_t mosi32, uint32_t miso32);

// ---------------- decoder ----------------
static int      prev_rs = -1;
static uint32_t abits = 0, amosi = 0;
static int      cur_addr = -1;
static uint32_t dbits = 0, dmosi = 0, dmiso = 0;
static uint32_t wmosi[2], wmiso[2];
static uint32_t nwords = 0, npairs = 0;

static char     last_line[64] = "";
static uint32_t last_count = 0;

static void flush_line() {
    if (last_count == 0) return;
    if (last_count > 1) Serial.printf("%s  (x%lu)\n", last_line, (unsigned long)last_count);
    else                Serial.printf("%s\n", last_line);
    last_count = 0;
}

static void out_line(const char *s) {
    if (last_count && strcmp(s, last_line) == 0) { last_count++; return; }
    flush_line();
    strncpy(last_line, s, sizeof(last_line) - 1);
    last_count = 1;
}

static bool filter_pair(int addr, uint32_t pairs_before, uint32_t mosi32, uint32_t miso32) {
    if (mode == MODE_ALL) return false;
    if (addr < 0 || pairs_before != 0) return true;      // ReadAgain / unknown: suppress
    bool is_read = (mosi32 == 0) && (miso32 != 0 || is_read_reg(addr));
    if (mode == MODE_CHANGES) {
        if (is_read || addr > 0x3F) return true;
        if (last_w[addr] != (int64_t)mosi32) {
            flush_line();
            stamp();
            Serial.printf("W %02x = %08lx\n", addr, (unsigned long)mosi32);
            last_w[addr] = mosi32;
        }
        return true;
    }
    // MODE_FILTER
    if (addr == 0x05) {
        for (int b = 31; b >= 0; b--) {
            uint32_t m = 1u << b;
            if (!(WATCH05 & m)) continue;
            int now = (mosi32 & m) ? 1 : 0;
            if (last05 < 0 || (int)((last05 >> b) & 1) != now) {
                stamp();
                Serial.printf("reg 0x05 bit %d -> %d   (W 05 = %08lx)\n", b, now, (unsigned long)mosi32);
            }
        }
        last05 = mosi32;
    } else if (addr == 0x00) {
        stamp();
        Serial.printf("reg 0x00 written, value = %08lx\n", (unsigned long)mosi32);
    }
    return true;
}

// Flash reads (W17 address, pulses 0d, busy 15, R 0c) are combined into one line
// "FR aaaaaa -> bb" so that the output keeps up.
static int32_t  flash_addr = -1;
static bool     flash_printed = true;

static bool compact_flash(uint32_t mosi32, uint32_t miso32) {
    if (cur_addr == 0x17 && npairs == 0 && mosi32 != 0) {   // new flash address
        flash_addr = (int32_t)mosi32; flash_printed = false; npairs++; return true;
    }
    if (cur_addr == 0x0d || cur_addr == 0x15) { npairs++; return true; }  // strobes / busy
    if (cur_addr == 0x0c) {
        if (!flash_printed && flash_addr >= 0) {
            char buf[64];
            snprintf(buf, sizeof buf, "FR %06lx -> %02lx", (unsigned long)flash_addr, (unsigned long)(miso32 & 0xFF));
            out_line(buf);
            flash_printed = true;
        }
        npairs++; return true;
    }
    return false;
}

static void emit_pair(uint32_t mosi32, uint32_t miso32) {
    char buf[64];
    if (filter_pair(cur_addr, npairs, mosi32, miso32)) { npairs++; return; }
    if (compact_flash(mosi32, miso32)) return;
    if (cur_addr < 0) {
        snprintf(buf, sizeof buf, "R+ ?? -> %08lx", (unsigned long)miso32);
    } else if (npairs > 0) {
        snprintf(buf, sizeof buf, "R+ %02x -> %08lx", cur_addr, (unsigned long)miso32);
    } else if (mosi32 != 0) {
        snprintf(buf, sizeof buf, "W %02x = %08lx", cur_addr, (unsigned long)mosi32);
    } else if (miso32 != 0) {
        snprintf(buf, sizeof buf, "R %02x -> %08lx", cur_addr, (unsigned long)miso32);
    } else {
        snprintf(buf, sizeof buf, "?  %02x  (write of 0 or read of 0)", cur_addr);
    }
    out_line(buf);
    npairs++;
}

// one sample (4 bits) per rising SCK edge
static inline void feed(uint32_t nib) {
    uint32_t mosi = nib & 1, miso = (nib >> 1) & 1, rs = (nib >> 2) & 1;
    if (rs == 0) {
        if (prev_rs != 0) {
            if (prev_rs == 1 && (dbits || nwords) && mode == MODE_ALL) out_line("!  alignment lost (data incomplete)");
            abits = 0; amosi = 0;
        }
        amosi = (amosi << 1) | mosi;
        if (++abits == 16) {
            cur_addr = amosi & 0xFFFF;
            abits = 0; amosi = 0;
            npairs = 0;
        }
    } else {
        if (prev_rs != 1) {
            if (prev_rs == 0 && abits && mode == MODE_ALL) out_line("!  alignment lost (address incomplete)");
            dbits = 0; dmosi = 0; dmiso = 0; nwords = 0;
        }
        dmosi = (dmosi << 1) | mosi;
        dmiso = (dmiso << 1) | miso;
        if (++dbits == 16) {
            wmosi[nwords] = dmosi & 0xFFFF;
            wmiso[nwords] = dmiso & 0xFFFF;
            dbits = 0; dmosi = 0; dmiso = 0;
            if (++nwords == 2) {
                emit_pair((wmosi[0] << 16) | wmosi[1], (wmiso[0] << 16) | wmiso[1]);
                nwords = 0;
            }
        }
    }
    prev_rs = (int)rs;
}

void setup() {
    Serial.begin(115200);
    for (int i = 0; i < 64; i++) last_w[i] = -1;
    setup_pio();
    dma_ch = dma_claim_unused_channel(true);
    start_dma();
    delay(1500);              // give the USB serial port time to enumerate
    banner();
}

static uint32_t last_flush_ms = 0;

void loop() {
    if (!dma_channel_is_busy(dma_ch)) {      // restart after ~4 billion words
        produced_base += DMA_COUNT;
        start_dma();
    }
    uint64_t prod = produced_now();
    if (prod - consumed > RING_WORDS) {
        flush_line();
        Serial.printf("!  OVERFLOW: %llu words lost\n", (unsigned long long)(prod - consumed - RING_WORDS));
        consumed = prod - RING_WORDS / 2;
        prev_rs = -1; cur_addr = -1;
    }
    // mode keys
    while (Serial.available()) {
        int c = Serial.read();
        if (c == 'a' || c == 'A') { flush_line(); mode = MODE_ALL; banner(); }
        if (c == 'c' || c == 'C') { flush_line(); mode = MODE_CHANGES; for (int i = 0; i < 64; i++) last_w[i] = -1; banner(); }
        if (c == 'f' || c == 'F') { flush_line(); mode = MODE_FILTER; last05 = -1; banner(); }
    }
    uint32_t budget = 2048;
    while (consumed < prod && budget--) {
        uint32_t w = ring[consumed % RING_WORDS];
        for (int s = 28; s >= 0; s -= 4) feed((w >> s) & 0xF);
        consumed++;
    }
    // print pending repeated lines regularly
    if (millis() - last_flush_ms > 200) {
        flush_line();
        last_flush_ms = millis();
    }
}
