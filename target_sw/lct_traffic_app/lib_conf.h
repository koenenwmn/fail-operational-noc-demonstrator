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
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 *   Thomas Hallermeier <thomas.hallermeier@tum.de>
 */

#include <or1k-support.h>
#include <stdlib.h>
#include <optimsoc-baremetal.h>

/**
 * Initialize config library.
 */
void lib_conf_init(volatile uint16_t *x_dim, volatile uint16_t *y_dim,
        volatile uint32_t *min_burst, volatile uint32_t *max_burst,
        volatile uint32_t *min_delay, volatile uint32_t *max_delay,
        volatile uint32_t *seed, volatile uint32_t *lot,
        volatile uint16_t *num_tiles, volatile uint16_t *num_lot_reg,
        volatile uint8_t *lcts, volatile uint16_t *num_lcts);
