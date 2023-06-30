/* Copyright (c) 2019-2020 by the author(s)
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
 * Demo to create BE background traffic in the hybrid NoC.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Thomas Hallermeier <thomas.hallermeier@tum.de>
 */

#include <stdio.h>
#include <or1k-support.h>
#include <optimsoc-baremetal.h>
#include "../lib_hybrid_mp_simple/hybrid_mp_simple_ps.h"
#include "lib_conf.h"

// Enable debug messages to be printed out
//#define DEBUG
// Print message when faulty packet arrives -> leads to back pressure in the NoC
#define REPORTFAULT

#define MAXTILES 256

int volatile _tile_id;

static volatile uint16_t _x_dim;
static volatile uint16_t _y_dim;
static volatile uint32_t _min_burst;
static volatile uint32_t _max_burst;
static volatile uint32_t _min_delay;
static volatile uint32_t _max_delay;
static volatile uint32_t _seed;
static volatile uint32_t* _lot;

static volatile uint16_t _num_tiles;
static volatile uint16_t _num_lot_reg;

static volatile uint8_t* _lcts;
static volatile uint16_t _num_lcts;

/**
 * This is the handler for class 0 messages
 *
 * Class 0 is used for the traffic between the tiles
 */
void clss_0_hndl (uint32_t *buffer, size_t len) {
    int success = 1;
    // Check if length is correct
    if (len != 6)
        success = 0;
    // Check if src, dest, and link words are uncorrupted and dest matches tile id
    if ((buffer[1] & 0xffff) != ((buffer[1] >> 16) & 0xffff))
        success = 0;
    if ((buffer[2] & 0xffff) != ((buffer[2] >> 16) & 0xffff))
        success = 0;
    if ((buffer[3] & 0xffff) != ((buffer[3] >> 16) & 0xffff))
        success = 0;
    if ((buffer[1] & 0xffff) != _tile_id)
        success = 0;
    // Check if payload words are correct
    if (buffer[4] != ('p' | ('i' << 8) | ('n' << 16) | ('g' << 24)))
        success = 0;
    if (buffer[5] != 0)
        success = 0;
    if (success == 0) {
#ifdef REPORTFAULT
        printf("Corrupt pkt len %lu:\n", len);
        for (int i = 0; i < len; i++)
            printf("%lx\n",buffer[i]);
#endif
        return;
    }
#ifdef DEBUG
    uint16_t src = buffer[2] & 0xffff;
    uint16_t link = buffer[3] & 0xffff;
    printf("Received 'ping' from %u on link %u\n", src, link);
#endif
}

void create_msg(uint32_t *msg, int dest, int link) {
    // First word is destination tile twice
    msg[0] = (dest & 0xffff) << 16 | (dest & 0xffff);
    // Second word is source tile twice
    msg[1] = (_tile_id & 0xffff) << 16 | (_tile_id & 0xffff);
    // Third word is link twice
    msg[2] = (link & 0xffff) << 16 | (link & 0xffff);
}

int main() {
    if (optimsoc_get_relcoreid() != 0) {
        return 0;
    }

    // Initialize optimsoc library
    optimsoc_init(0);
#ifdef DEBUG
    printf("OpTiMSoC initialized\n");
#endif
    // Initialize hybrid library
    hybrid_mp_simple_init_ps();
#ifdef DEBUG
    printf("BE initialized\n");
#endif
    // Add handler for BE packet class 0
    hybrid_mp_simple_addhandler_ps(0, &clss_0_hndl);
#ifdef DEBUG
    printf("BE handler set\n");
#endif
    // Enable BE endpoints
    uint8_t endpoints = hybrid_mp_simple_num_endpoints_ps();
#ifdef DEBUG
    printf("%d BE EPs discovered\n", endpoints);
#endif
    for (int i = 0; i < endpoints; i++){
        hybrid_mp_simple_enable_ps(i);
#ifdef DEBUG
        printf("BE EP %d enabled\n", i);
#endif
    }
    // Initialize surveillance module library
    _num_tiles = REG32(OPTIMSOC_NA_NUMTILES);
    _num_lot_reg = ((_num_tiles-1)/32)+1;
    _lot = malloc(_num_lot_reg * sizeof(uint32_t));
    _lcts = malloc(_num_tiles * sizeof(uint8_t));
    lib_conf_init(&_x_dim, &_y_dim, &_min_burst, &_max_burst, &_min_delay, &_max_delay, &_seed, _lot, &_num_tiles, &_num_lot_reg, _lcts, &_num_lcts);
#ifdef DEBUG
    printf("Surveillance module config. initialized\n");
#endif

    // Enable interrupts
    or1k_interrupts_enable();
#ifdef DEBUG
    printf("Interrupts enabled\n");
#endif

    // Determine tiles rank
    int rank = optimsoc_get_ctrank();
    _tile_id = optimsoc_get_tileid();

    printf("Rank %d initialized. Tile ID: %d\n", rank, _tile_id);

    // Wait until dimensions are set
    while (_x_dim == 0 && _y_dim == 0);
#ifdef DEBUG
        printf("x: %u, y: %u\n", _x_dim, _y_dim);
#endif
    if (hybrid_mp_simple_get_routing_type() == 0) {
#ifdef DEBUG
        printf("Calculate headers..\n");
#endif
        hybrid_mp_simple_create_header_table_sr(_x_dim, _y_dim);
    }

    // Wait until random seed has been configured
    while (_seed == 0);
#ifdef DEBUG
    printf("Seeding with %lu\n", _seed);
#endif
    srand(_seed);

#ifdef DEBUG
    printf("Starting Program..\n");
#endif

    // Only a simple message of fixed length is sent to generate traffic
    uint32_t msg[5];
    // A payload word ('ping') and null word are fixed. The rest of the message
    // contains destination and link for validity checks.
    msg[3] = 'p' | ('i' << 8) | ('n' << 16) | ('g' << 24);
    msg[4] = 0;

    int burst = 0;
    int link = 0;
    int dest_lct = 0;
    int dest = 0;
    int delay = 0;

    while (1) {
#ifdef DEBUG
        printf("Waiting for activation..\n");
#endif
        // Wait, in case the application got deactivated
        while (_num_lcts == 0 || _max_burst == 0);
#ifdef DEBUG
        printf("num_lcts: %u, max_burst: %lu\n", _num_lcts, _max_burst);
#endif

        dest_lct = _num_lcts > 1 ? (rand() % _num_lcts) : 0;
        dest = _lcts[dest_lct];
        // Send messages in burst
        if (_max_burst == _min_burst) {
            burst = _max_burst;
        }
        else {
            burst = (rand() % (_max_burst - _min_burst)) + _min_burst;
        }
        link = rand() % endpoints;
#ifdef DEBUG
        printf("burst %d to %d link %d\n", burst, dest, link);
#endif
        // Create message
        create_msg(msg, dest, link);
        for (int i = 0; i < burst; i++) {
            hybrid_mp_simple_send_ps(dest, link, 0, 0, 5, (uint32_t*) msg);
        }
        // Delay next burst
        if (_max_delay > 0) {
            if (_max_delay == _min_delay) {
                delay = _max_delay;
            }
            else {
                delay = (rand() % (_max_delay - _min_delay)) + _min_delay;
            }
#ifdef DEBUG
            printf("wait:%d\n", delay);
#endif
            for (int i = 0; i < delay; i++);
        }
    }

    return 0;
}
