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

#include <or1k-support.h>
#include <stdlib.h>
#include <optimsoc-baremetal.h>

/**
 * Initialize packet switching library.
 */
void hybrid_mp_simple_init_ps(void);

/**
 * Creates a table containing all headers for source routing.
 *
 * The table entries can be retrieved by using hybrid_mp_simple_get_tile_header(),
 * hybrid_mp_simple_get_rank_header(), or hybrid_mp_simple_get_header_sr().
 *
 * \param x_dim The x dimension of the NoC
 * \param y_dim The y dimension of the NoC
 */
void hybrid_mp_simple_create_header_table_sr(uint8_t x_dim, uint8_t y_dim);

/**
 * Calculate source tile and endpoint for source routing.
 *
 * The source routing part of a header gives the reverse path to the source.
 * This function calculates the source tile and endpoint by following the path.
 * \param path Path to source
 * \return Returns the source tile (bits 0 to 30) and endpoint (bit 31)
 *         In case of an error ~0 is returned
 */
uint32_t hybrid_mp_simple_get_source_sr(uint32_t path);

/**
 * Enables a specified packet-switching endpoint.
 *
 * \param endpoint The endpoint to enable.
 * \return '0' on success, '-1' otherwise
 */
int hybrid_mp_simple_enable_ps(uint16_t endpoint);

/**
 * Returns the number of packet-switching endpoints.
 *
 * \return Number of endpoints
 */
uint16_t hybrid_mp_simple_num_endpoints_ps();

/**
 * Returns the routing type for packet-switching in the NoC.
 *
 * Returns '1' for distributed routing and '0' for source routing.
 * \return Routing type
 */
uint8_t hybrid_mp_simple_get_routing_type(void);

/**
 * Returns a header for source routing.
 *
 * hybrid_mp_simple_create_header_table_sr() must have been called before.
 * \param tile Destination tile
 * \param endpoint Destination endpoint
 * \param msg_class Message class
 * \param specific Class specific header information
 * \return Header for source routing
 */
uint32_t hybrid_mp_simple_get_header_sr(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific);

/**
 * Returns a header for distributed routing.
 *
 * \param tile Destination tile
 * \param endpoint Destination endpoint
 * \param msg_class Message class
 * \param specific Class specific header information
 * \return Header for distributed routing
 */
uint32_t hybrid_mp_simple_get_header_dr(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific);

/**
 * Returns a header for routing type used by the NoC.
 *
 * hybrid_mp_simple_create_header_table_sr() must have been called before in
 * in case source routing is used.
 * \param tile Destination tile
 * \param endpoint Destination endpoint
 * \param msg_class Message class
 * \param specific Class specific header information
 * \return Header for routing type used by NoC
 */
uint32_t hybrid_mp_simple_get_tile_header(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific);

/**
 * Returns a header for routing type used by the NoC. Rank version.
 *
 * hybrid_mp_simple_create_header_table_sr() must have been called before in
 * in case source routing is used.
 * \param rank Destination core rank
 * \param endpoint Destination endpoint
 * \param msg_class Message class
 * \param specific Class specific header information
 * \return Header for routing type used by NoC
 */
uint32_t hybrid_mp_simple_get_rank_header(uint16_t rank, uint16_t endpoint, uint8_t msg_class, uint16_t specific);

/**
 * Check if a remote packet switching endpoint is enabled.
 *
 * Always returns '0' the first time called. Needs to be called again after some
 * time to give the remote endpoint time to answer. Sends a request via the NoC
 * whenever a tile is not marked as enabled.
 * \param tile Remote tile to check
 * \param endpoint Remote endpoint to check
 * \return '1' if a remote endpoint is marked as enabled, '0' otherwise
 */
int hybrid_mp_simple_tile_ready(uint32_t tile, uint16_t endpoint);

/**
 * Check if a remote packet switching endpoint is enabled. Rank version.
 *
 * Rank version of hybrid_mp_simple_tile_ready()
 * \param tile Remote tile to check
 * \param endpoint Remote endpoint to check
 * \return '1' if a remote endpoint is marked as enabled, '0' otherwise
 */
int hybrid_mp_simple_ctready(uint32_t rank, uint16_t endpoint);

/**
 * Add handler for a specific message class.
 *
 * \param msg_class Message class to add handler for
 * \param hnd Reference to handler function
 * \return '0' if adding succeeded, '1' if class is greater than OPTIMSOC_CLASS_NUM
 */
int hybrid_mp_simple_addhandler_ps(uint8_t msg_class, void (*hnd)(uint32_t*, size_t));

/**
 * Sends a specified number of words from a buffer via a specified endpoint.
 *
 * The header must already be part of the data in the buffer.
 * \param endpoint Endpoint to send out on
 * \param size Number of words to send
 * \param buf Reference to buffer
 */
void hybrid_mp_simple_send_ps_raw(uint16_t endpoint, size_t size, uint32_t *buf);

/**
 * Sends a specified number of words from a buffer, adding a header.
 *
 * \param tile Destination tile
 * \param endpoint Endpoint to send out on and to send to
 * \param msg_class Message class
 * \param specific Class specific information
 * \param size Number of worde to send
 * \param buf Reference to buffer
 */
void hybrid_mp_simple_send_ps(uint16_t tile, uint16_t endpoint, uint8_t msg_class, uint16_t specific, size_t size, uint32_t *buf);
