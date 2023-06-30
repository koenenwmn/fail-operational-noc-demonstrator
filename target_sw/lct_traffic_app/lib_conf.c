/* Copyright (c) 2020 by the author(s)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * =============================================================================
 *
 * Driver for the configuration functionality of the surveillance module.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 *   Thomas Hallermeier <thomas.hallermeier@tum.de>
 */

#include "lib_conf.h"
#include <stdio.h>

#define SM_BASE         0xa0000000
#define REG_ADDR        0x000
#define REG_XYDIM       0x300
#define REG_MINBURST    0x304
#define REG_MAXBURST    0x308
#define REG_MINDELAY    0x30c
#define REG_MAXDELAY    0x310
#define REG_SEED        0x314
#define REG_LOT_BASE    0x400

#define IRQ         7

#define READ(reg) REG32(SM_BASE + reg)


static void _conf_irq_handler(void* arg);
static void _create_lcts();

static volatile uint16_t *_x_dim;
static volatile uint16_t *_y_dim;
static volatile uint32_t *_min_burst;
static volatile uint32_t *_max_burst;
static volatile uint32_t *_min_delay;
static volatile uint32_t *_max_delay;
static volatile uint32_t *_seed;
static volatile uint32_t *_lot; // array with size depending on *_num_tiles (1 per 32 tiles)

static volatile uint16_t *_num_tiles;
static volatile uint16_t *_num_lot_reg;

static volatile uint8_t *_lcts; // array of size *_num_tiles
static volatile uint16_t *_num_lcts;


void lib_conf_init(volatile uint16_t *x_dim, volatile uint16_t *y_dim,
        volatile uint32_t *min_burst, volatile uint32_t *max_burst,
        volatile uint32_t *min_delay, volatile uint32_t *max_delay,
        volatile uint32_t *seed, volatile uint32_t *lot,
        volatile uint16_t *num_tiles, volatile uint16_t *num_lot_reg,
        volatile uint8_t *lcts, volatile uint16_t *num_lcts) {
    // Initialize interrupt handling for configuration
    or1k_interrupt_handler_add(IRQ, &_conf_irq_handler, 0);

    // Initialize pointers
    _x_dim = x_dim;
    _y_dim = y_dim;
    _min_burst = min_burst;
    _max_burst = max_burst;
    _min_delay = min_delay;
    _max_delay = max_delay;
    _seed = seed;
    _lot = lot;

    _num_tiles = num_tiles;
    _num_lot_reg = num_lot_reg;

    _lcts = lcts;
    _num_lcts = num_lcts;

    or1k_interrupt_enable(IRQ);
}

void _conf_irq_handler(void* arg) {
    (void)arg;

    // Once an interrupt has been issued, read address of changed register and
    // then read that register. Repeat this until interrupt is served.
    uint16_t addr = READ(REG_ADDR);
    while (addr != 0x000) {
        uint32_t data = READ(addr);
        if (addr == REG_XYDIM) {
            *_y_dim = data & 0xffff;
            *_x_dim = (data >> 16) & 0xffff;
        } else if (addr == REG_MINBURST)
            *_min_burst = data;
        else if (addr == REG_MAXBURST)
            *_max_burst = data;
        else if (addr == REG_MINDELAY)
            *_min_delay = data;
        else if (addr == REG_MAXDELAY)
            *_max_delay = data;
        else if (addr == REG_SEED)
            *_seed = data;
        else if (addr >= REG_LOT_BASE && addr <= REG_LOT_BASE + *_num_lot_reg - 1) {
            uint8_t idx = addr & 0xff;
            _lot[idx] = data;
            _create_lcts();
        }
        addr = READ(REG_ADDR);
    }
}

// transform _lot where each bit indicates a tile to a list of actual tile ids
void _create_lcts() {
    *_num_lcts = 0;
    for (int i = 0; i < *_num_lot_reg; i++) {
        for (int j = 0; j < 32 && (j + i*32) < *_num_tiles; j++) {
            if ((_lot[i] >> j) & 0x1) {
                _lcts[*_num_lcts] = (j + i*32);
                *_num_lcts = *_num_lcts + 1;
            }
        }
    }
}
