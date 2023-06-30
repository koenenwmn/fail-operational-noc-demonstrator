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
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

#include <or1k-support.h>
#include <stdlib.h>
#include <optimsoc-baremetal.h>

/**
 * Initialize TDM library.
 */
void hybrid_mp_simple_init_tdm(void);

/**
 * Enables a specified TDM endpoint.
 *
 * \param endpoint The endpoint to enable.
 */
void hybrid_mp_simple_enable_tdm(uint16_t endpoint);

/**
 * Returns the number of TDM endpoints.
 *
 * \return Number of endpoints
 */
uint32_t hybrid_mp_simple_num_endpoints_tdm(void);

/**
 * Add handler for a specific TDM endpoint.
 *
 * \param endpoint Endpoint to add handler for
 * \param handler Reference to handler function
 * \return '0' if adding succeeded, '1' if ep is greater than number of endpoints
 */
int hybrid_mp_simple_addhandler_tdm(uint32_t endpoint, void handler(uint32_t*, size_t));

/**
 * Sends a specified number of words from a buffer via a specified endpoint.
 *
 * \param endpoint Endpoint to send out on
 * \param size Number of worde to send
 * \param buf Reference to buffer
 */
void hybrid_mp_simple_send_tdm(uint16_t endpoint, size_t size, uint32_t* buf);
