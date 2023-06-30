/* Copyright (c) 2020-2022 by the author(s)
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
 * Driver for the packet-switched simple message passing hardware of the hybrid
 * NoC.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

#include "hybrid_mp_simple_ps.h"

#define BASE        (OPTIMSOC_NA_BASE + 0x100000)
#define EP_OFFSET   0x2000
#define REG_INFO    BASE
#define EP_BASE     (BASE + EP_OFFSET)
#define REG_SEND    0x0
#define REG_RECV    0x0
#define REG_ENABLE  0x4
#define IRQ         3

#define SEND(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_SEND)
#define RECV(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_RECV)
#define ENABLE(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_ENABLE)

#define HYBRID_DEST_LSB 0
#define HYBRID_DEST_MSB 9
#define HYBRID_SRC_LSB 10
#define HYBRID_SRC_MSB 19
#define HYBRID_SPECIFIC_SR_LSB 24
#define HYBRID_SPECIFIC_SR_MSB 28
#define HYBRID_SPECIFIC_DR_LSB 24
#define HYBRID_SPECIFIC_DR_MSB 28
#define HYBRID_DR_LINK 23
#define HYBRID_CLASS_LSB 29
#define HYBRID_CLASS_MSB 31

#define EXTRACT(x,msb,lsb) ((x>>lsb) & ~(~0 << (msb-lsb+1)))

// Local buffer for the simple message passing
static uint32_t* _buffer;

// Local table for source routing
static uint32_t* _headers;

// List of handlers for the BE classes
void (*_cls_handlers[OPTIMSOC_CLASS_NUM])(uint32_t*, size_t);

static void _ps_irq_handler(void* arg);
uint32_t hybrid_mp_simple_calculate_header_sr(uint16_t dest, uint16_t link);

static volatile uint8_t* _tiles_ready;

static uint16_t _num_endpoints;
static uint16_t _num_tiles;
static uint16_t _tile_id;
static uint8_t _routing_type;
static uint8_t _x_dim;
static uint8_t _y_dim;

void hybrid_mp_simple_init_ps(void) {
    // Register interrupt
    or1k_interrupt_handler_add(IRQ, &_ps_irq_handler, 0);

    // Reset class handler
    for (int i = 0; i < OPTIMSOC_CLASS_NUM; i++) {
        _cls_handlers[i] = 0;
    }

    uint32_t ps_info = REG32(REG_INFO);
    _num_endpoints = ps_info & 0xffff;
    _routing_type = ps_info >> 31;
    _tile_id = optimsoc_get_tileid();
    _num_tiles = REG32(OPTIMSOC_NA_NUMTILES);
    _tiles_ready = calloc(_num_tiles, sizeof(uint8_t));

    // Allocate buffer
    _buffer = malloc(optimsoc_noc_maxpacketsize() * sizeof(uint32_t));

    // Enable interrupt
    or1k_interrupt_enable(IRQ);
}

uint32_t hybrid_mp_simple_calculate_header_sr(uint16_t dest, uint16_t link) {
    uint32_t dest_x = dest % _x_dim;
    uint32_t dest_y = dest / _x_dim;
    uint32_t curr_x = _tile_id % _x_dim;
    uint32_t curr_y = _tile_id / _x_dim;
    uint32_t hop = 0;
    uint32_t header = 0;
    uint32_t nhop;

    // Route in x-dim
    while (dest_x != curr_x) {
        if (dest_x < curr_x) {
            nhop = 3;
            curr_x--;
        }
        else {
            nhop = 1;
            curr_x++;
        }
        header |= (nhop & 0x7) << (hop * 3);
        hop++;
    }
    // Route in y-dim
    while (dest_y != curr_y) {
        if (dest_y < curr_y) {
            nhop = 0;
            curr_y--;
        }
        else {
            nhop = 2;
            curr_y++;
        }
        header |= (nhop & 0x7) << (hop * 3);
        hop++;
    }
    header |= ((4 + link) & 0x7) << (hop * 3);
    return header;
}

void hybrid_mp_simple_create_header_table_sr(uint8_t x_dim, uint8_t y_dim) {
    _x_dim = x_dim;
    _y_dim = y_dim;
    uint32_t num_headers = _num_tiles * _num_endpoints;
    _headers = calloc(num_headers, sizeof(uint32_t));
    for (uint16_t ep = 0; ep < _num_endpoints; ep++) {
        for (uint16_t tile = 0; tile < _num_tiles; tile++) {
            uint32_t header = hybrid_mp_simple_calculate_header_sr(tile, ep);
            _headers[ep * _num_tiles + tile] = header;
        }
    }
}

uint32_t hybrid_mp_simple_get_source_sr(uint32_t path) {
    uint16_t curr_tile = _tile_id;
    int ep = -1;
    while (ep < 0) {
        switch (path & 0x7) {
            case 0: curr_tile -= _x_dim; break;
            case 1: curr_tile++; break;
            case 2: curr_tile += _x_dim; break;
            case 3: curr_tile--; break;
            case 4: ep = 0; break;
            case 5: ep = 1; break;
            default: return ~0;
        }
        path >>= 3;
    }
    return (ep & 0x1) << 31 | curr_tile;
}

int hybrid_mp_simple_enable_ps(uint16_t endpoint) {
    if (endpoint < _num_endpoints) {
        ENABLE(endpoint) = 1;
        return 0;
    }
    else
        return -1;
}

uint16_t hybrid_mp_simple_num_endpoints_ps() {
    return _num_endpoints;
}

uint8_t hybrid_mp_simple_get_routing_type(void) {
    return _routing_type;
}

uint32_t hybrid_mp_simple_get_header_sr(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific) {
    uint32_t header = (msg_class & 0x7) << HYBRID_CLASS_LSB | (specific & 0x1f) << HYBRID_SPECIFIC_SR_LSB | _headers[endpoint * _num_tiles + tile];
    return header;
}

uint32_t hybrid_mp_simple_get_header_dr(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific) {
    return (msg_class & 0x7) << HYBRID_CLASS_LSB | (specific & 0x1f) << HYBRID_SPECIFIC_DR_LSB |
            (endpoint & 0x1) << HYBRID_DR_LINK | (_tile_id & 0x3ff) << HYBRID_SRC_LSB | (tile & 0x3ff);
}

uint32_t hybrid_mp_simple_get_tile_header(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific) {
    if (_routing_type)
        return hybrid_mp_simple_get_header_dr(tile, endpoint, msg_class, specific);
    else
        return hybrid_mp_simple_get_header_sr(tile, endpoint, msg_class, specific);
}

uint32_t hybrid_mp_simple_get_rank_header(uint16_t rank, uint16_t endpoint, uint8_t msg_class, uint16_t specific) {
    return hybrid_mp_simple_get_tile_header(optimsoc_get_ranktile(rank), endpoint, msg_class, specific);
}

int hybrid_mp_simple_tile_ready(uint32_t tile, uint16_t endpoint) {
    uint8_t ready = _tiles_ready[tile];
    if ((ready >> endpoint) & 0x1) {
        return 1;
    }

    uint32_t req = hybrid_mp_simple_get_tile_header(tile, endpoint, OPTIMSOC_CLASS_NUM - 1, 0);
    SEND(endpoint) = 1;
    SEND(endpoint) = req;

    return 0;
}

int hybrid_mp_simple_ctready(uint32_t rank, uint16_t endpoint) {
    return hybrid_mp_simple_tile_ready(optimsoc_get_ranktile(rank), endpoint);
}

int hybrid_mp_simple_addhandler_ps(uint8_t msg_class, void (*hnd)(uint32_t*, size_t)) {
    if (msg_class >= OPTIMSOC_CLASS_NUM)
        return 1;
    _cls_handlers[msg_class] = hnd;
    return 0;
}

void _ps_irq_handler(void* arg) {
    (void)arg;

    uint16_t ep = 0;
    while (ep < _num_endpoints) {
        // Store message in buffer
        // Get size
        size_t size = RECV(ep);

        if (size == 0) {
            // There are no further messages in the buffer
            ep++;
            continue;
        }
        else if (optimsoc_noc_maxpacketsize() < size) {
            // Abort and drop if message cannot be stored
            //printf("FATAL: not sufficent buffer space. Drop packet\n");
            for (int i = 0; i < size; i++) {
                RECV(ep);
            }
        }
        else {
            for (int i = 0; i < size; i++) {
                _buffer[i] = RECV(ep);
            }
        }

        uint32_t header = _buffer[0];
        // Extract class
        uint8_t msg_class = EXTRACT(header, HYBRID_CLASS_MSB, HYBRID_CLASS_LSB);

        if (msg_class == OPTIMSOC_CLASS_NUM - 1) {
            // Distributed routing
            if (_routing_type) {
                uint8_t specific = EXTRACT(header, HYBRID_SPECIFIC_DR_MSB, HYBRID_SPECIFIC_DR_LSB);
                if (specific) {
                    uint8_t endpoint = (header >> HYBRID_DR_LINK) & 0x1;
                    uint16_t tile = EXTRACT(header, HYBRID_SRC_MSB, HYBRID_SRC_LSB);
                    _tiles_ready[tile] |= 1 << endpoint;
                }
            }
            // Source routing
            else {
                uint8_t specific = EXTRACT(header, HYBRID_SPECIFIC_SR_MSB, HYBRID_SPECIFIC_SR_LSB);
                if (specific) {
                    uint32_t source = hybrid_mp_simple_get_source_sr(header);
                    uint16_t tile = source & 0xffff;
                    uint8_t endpoint = source >> 31;
                    _tiles_ready[tile] |= 1 << endpoint;
                }
            }
        }
        else {

            // Call respective class handler
            if (_cls_handlers[msg_class] == 0) {
                // No handler registered, packet gets lost
                //printf("Packet of unknown class (%d) received. Drop.\n",class);
                continue;
            }

            _cls_handlers[msg_class](_buffer, size);
        }
    }
}

void hybrid_mp_simple_send_ps_raw(uint16_t endpoint, size_t size, uint32_t* buf) {
    uint32_t restore = or1k_critical_begin();

    SEND(endpoint) = size;
    for (int i = 0; i < size; i++) {
        SEND(endpoint) = buf[i];
    }

    or1k_critical_end(restore);
}

void hybrid_mp_simple_send_ps(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific, size_t size, uint32_t* buf) {
    uint32_t restore = or1k_critical_begin();

    SEND(endpoint) = size + 1;
    SEND(endpoint) = hybrid_mp_simple_get_tile_header(tile, endpoint, msg_class, specific);
    for (int i = 0; i < size; i++) {
        SEND(endpoint) = buf[i];
    }

    or1k_critical_end(restore);
}
