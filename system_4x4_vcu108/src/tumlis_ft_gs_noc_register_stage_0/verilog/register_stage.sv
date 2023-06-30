/* Copyright (c) 2018-2020 by the author(s)
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
 * This is a single register stage for a flit and a configurable number of
 * flags. It is used in the input and output stage of a router.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module register_stage #(
   parameter FLIT_WIDTH = 'x,
   parameter FLAGS = 'x
)(
   input clk,
   input rst,

   input [FLIT_WIDTH-1:0]  in_flit,
   input [FLAGS-1:0]       in_flags,

   output reg [FLIT_WIDTH-1:0] out_flit,
   output reg [FLAGS-1:0]      out_flags
);

   always_ff @(posedge clk) begin
      if (rst) begin
         out_flags <= 0;
      end else begin
         out_flit <= in_flit;
         out_flags <= in_flags;
      end
   end

endmodule // register_stage
