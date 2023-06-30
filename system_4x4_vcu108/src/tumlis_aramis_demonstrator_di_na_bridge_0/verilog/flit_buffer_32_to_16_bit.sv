/* Copyright (c) 2019-2021 by the author(s)
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
 * The module transforms 32-bit flits to 16-bit flits.
 * Individual input flits can be marked as 16 bit flits to avoid pading them
 * with zeros.
 * The internal buffer is large enough to hold MAX_PKT_LEN 32-bit flits
 *
 * Author(s):
 *   Stefan Keller <stefan.keller@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

import dii_package::dii_flit;

module flit_buffer_32_to_16_bit #(
   parameter MAX_PKT_LEN      = 10,

   localparam IN_FLIT_WIDTH   = 32,
   localparam OUT_FLIT_WIDTH  = 16
)(
   input    clk,
   input    rst,

   input [IN_FLIT_WIDTH-1:0]           in_flit_data,
   input                               in_flit_valid,
   input                               in_flit_last,
   input                               in_flit_16,
   output                              in_flit_ready,

   output logic [OUT_FLIT_WIDTH-1:0]   out_flit_data,
   output                              out_flit_valid,
   output                              out_flit_last,
   input                               out_flit_ready
);

   enum {LOWER_BITS, UPPER_BITS} state, nxt_state;

   wire [IN_FLIT_WIDTH-1:0]      buf_flit_data;
   wire                          buf_flit_last;
   wire                          buf_flit_16;
   logic                         buf_flit_ready;

   assign out_flit_last = buf_flit_last & (state == UPPER_BITS);

   always @(posedge clk) begin
      if (rst) begin
         state <= LOWER_BITS;
      end else begin
         state <= nxt_state;
      end
   end

   always_comb begin
      nxt_state = state;
      buf_flit_ready = 0;

      case (state)
         LOWER_BITS: begin
            out_flit_data = buf_flit_data[15:0];
            if (out_flit_ready & out_flit_valid) begin
               // Stay in state if flit is only 16 bit wide, else go to upper bits state
               buf_flit_ready = buf_flit_16;
               if (buf_flit_16 == 0) begin
                  nxt_state = UPPER_BITS;
               end
            end
         end

         UPPER_BITS: begin
            out_flit_data = buf_flit_data[31:16];
            if (out_flit_ready & out_flit_valid) begin
               nxt_state = LOWER_BITS;
               buf_flit_ready = 1'b1;
            end
         end
      endcase
   end

   noc_buffer #(
      .FLIT_WIDTH    (33),
      .DEPTH         (1 << $clog2(MAX_PKT_LEN + 1)))  // +1 for the endpoint info
   u_16_bit_noc_buffer(
      .clk           (clk),
      .rst           (rst),
      .in_flit       ({in_flit_16, in_flit_data}),
      .in_valid      (in_flit_valid),
      .in_last       (in_flit_last),
      .in_ready      (in_flit_ready),

      .out_flit      ({buf_flit_16, buf_flit_data}),
      .out_valid     (out_flit_valid),
      .out_last      (buf_flit_last),
      .out_ready     (buf_flit_ready)
   );

endmodule
