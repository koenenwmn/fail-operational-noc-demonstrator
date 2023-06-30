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
 * Driver for the TDM simple message passing hardware of the hybrid NoC.
 *
 * TODO:
 *  - Implement usage of endpoint status register
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

#include "hybrid_mp_simple_tdm.h"

#define BASE        (OPTIMSOC_NA_BASE + 0x200000)
#define EP_OFFSET   0x2000
#define REG_INFO    BASE
#define EP_BASE     (BASE + EP_OFFSET)
#define REG_SEND    0x0
#define REG_RECV    0x0
#define REG_ENABLE  0x4
#define REG_STATUS  0x8
#define IRQ         5

#define SEND(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_SEND)
#define RECV(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_RECV)
#define ENABLE(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_ENABLE)
#define STATUS(ep) REG32(EP_BASE + ep*EP_OFFSET+REG_STATUS)

#define MAX_NUM_EP  16

static void _tdm_irq_handler(void* arg);

// Number of existing TDM endpoints
static uint16_t _num_tdm_channels;

// Max number of flits between two checkpoints
static uint16_t _max_msg_len;

// List of handlers for all TDM endpoints
void (*_channel_handlers[MAX_NUM_EP])(uint32_t*, size_t);

// Local buffer for incoming messages
static uint32_t* _buffer;

void hybrid_mp_simple_init_tdm(void) {
    // Initialize interrupt handling for TDM Traffic
    or1k_interrupt_handler_add(IRQ, &_tdm_irq_handler, 0);

    // Reset class handler
    for (int i = 0; i < MAX_NUM_EP; i++) {
        _channel_handlers[i] = 0;
    }

    uint32_t tdm_info = REG32(REG_INFO);
    _num_tdm_channels = tdm_info & 0xff;
    _max_msg_len = tdm_info >> 16;

    // Allocate message buffer
    _buffer = malloc(_max_msg_len * sizeof(uint32_t));

    // Enable interrupt
    or1k_interrupt_enable(IRQ);
}

uint32_t hybrid_mp_simple_num_endpoints_tdm(void) {
    return _num_tdm_channels;
}

void hybrid_mp_simple_enable_tdm(uint16_t endpoint) {
    ENABLE(endpoint) = 1;
}

int hybrid_mp_simple_addhandler_tdm(uint32_t endpoint, void handler(uint32_t*, size_t)) {
    if (endpoint >= _num_tdm_channels) {
        return 1;
    }
    _channel_handlers[endpoint] = handler;
    return 0;
}

void _tdm_irq_handler(void* arg) {
    (void)arg;

    // Once an interrupt has been issued, go through all TDM endpoints,
    // until none of them has an unread message left.
    uint16_t ep = 0;
    while (ep < _num_tdm_channels) {
        size_t size = RECV(ep);
        if (size == 0) {
            ep++;
            continue;
        }
        else if (size > _max_msg_len) {
            // Drain and dismiss the packet
            for (int i = 0; i < size; i++) {
                RECV(ep);
            }
        }
        else {
            // Read the packet into the tdm_buffer.
            for (int i = 0; i < size; i++) {
                _buffer[i] = RECV(ep);
            }
        }

        // Call respective class handler
        if (_channel_handlers[ep] == 0) {
            // No handler registered, packet gets lost
            //printf("Packet of unknown class (%d) received. Drop.\n",class);
            continue;
        }
        _channel_handlers[ep](_buffer, size);
    }
}

void hybrid_mp_simple_send_tdm(uint16_t endpoint, size_t size, uint32_t* buf) {
    uint32_t restore = or1k_critical_begin();

    for (int i = 0; i < size; i++) {
        SEND(endpoint) = buf[i];
    }

    or1k_critical_end(restore);
}
