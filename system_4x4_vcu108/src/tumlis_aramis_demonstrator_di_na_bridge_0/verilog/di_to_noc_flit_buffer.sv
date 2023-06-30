/* Copyright (c) 2019 by the author(s)
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
 * The module transforms 16-bit flits from the DI into 32-bit flits for the NoC.
 *
 * The first 16-bit word is always padded with zeros because it determines the
 * endpoint. The following flits are unpacked to 32-bit words. The last flit is
 * padded with zeros if needed.
 * This module has a direct dependency of 'in_flit_ready' on 'out_flit_ready'
 * which could lead to a critical path. This has been done to prevent stop-and-
 * go-behavior and should be acceptable as long as a FIFO is used directly
 * before and after this module.
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Max Koenen <max.koenen@tum.de>
 */

import dii_package::dii_flit;

module di_to_noc_buffer #(
   parameter DUMMYSHITPARAM = 1, // Necessary to appease Vivado 2019.2
   localparam NOC_FLIT_WIDTH = 32,
   localparam DI_FLIT_WIDTH = 16
)(
   input                               clk,
   input                               rst,
   input dii_flit                      in_flit,
   output                              in_flit_ready,

   input                               out_flit_ready,
   output [(NOC_FLIT_WIDTH-1):0]       out_flit_data,
   output                              out_flit_valid,
   output                              out_flit_last
);

   enum {IDLE, LSB, MSB}         state, nxt_state;

   reg [(NOC_FLIT_WIDTH-1):0]    reg_flit_data;
   reg                           reg_flit_valid;
   reg                           reg_flit_last;

   logic [(NOC_FLIT_WIDTH-1):0]  nxt_flit_data;
   logic                         nxt_flit_valid;
   logic                         nxt_flit_last;

   assign out_flit_data = reg_flit_data;
   assign out_flit_valid = reg_flit_valid;
   assign out_flit_last = reg_flit_last;

   wire flit_read;
   wire write_new_word;

   assign flit_read = out_flit_ready & out_flit_valid;
   assign in_flit_ready = flit_read | ~out_flit_valid;
   assign write_new_word = in_flit.valid & in_flit_ready;

   always @(posedge clk) begin
      if (rst) begin
         state <= IDLE;
         reg_flit_data <= {NOC_FLIT_WIDTH{1'b0}};
         reg_flit_valid <= 1'b0;
         reg_flit_last <= 1'b0;
      end else begin
         state <= nxt_state;
         reg_flit_data <= nxt_flit_data;
         reg_flit_valid <= nxt_flit_valid;
         reg_flit_last <= nxt_flit_last;
      end
   end

   always_comb begin
      nxt_state = state;

      nxt_flit_data = reg_flit_data;
      nxt_flit_valid = reg_flit_valid;
      nxt_flit_last = reg_flit_last;

      case (state)
         IDLE: begin
            if (write_new_word) begin
               nxt_flit_data = {16'b0, in_flit.data};
               // There should be no single flit packets at this point. If there
               // is one we simply drain it from the previous buffer.
               if (~in_flit.last) begin
                  nxt_flit_valid = 1'b1;
                  nxt_flit_last = 1'b0;
                  nxt_state = LSB;
               end
            end else if (flit_read) begin
               nxt_flit_valid = 1'b0;
            end
         end
         LSB: begin
            if (write_new_word) begin
               nxt_flit_data = {16'b0, in_flit.data};
               if (in_flit.last) begin
                  nxt_flit_valid = 1'b1;
                  nxt_flit_last = 1'b1;
                  nxt_state = IDLE;
               end else begin
                  nxt_flit_valid = 1'b0;
                  nxt_state = MSB;
               end
            end else if (flit_read) begin
               nxt_flit_valid = 1'b0;
            end
         end
         MSB: begin
            if (write_new_word) begin
               nxt_flit_valid = 1'b1;
               nxt_flit_data = {in_flit.data, reg_flit_data[15:0]};
               nxt_flit_last = in_flit.last;
               if (in_flit.last) begin
                  nxt_state = IDLE;
               end else begin
                  nxt_state = LSB;
               end
            end
         end
      endcase
   end
endmodule
