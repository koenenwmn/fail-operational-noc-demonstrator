/* Copyright (c) 2018-2019 by the author(s)
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
 * Logic and registers to create a FIFO with FWFT read characteristics.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module fifo_fwft_logic #(
   parameter WIDTH = 'x
)(
   input    clk,
   input    rst,

   input [WIDTH-1:0]       fifo_dout,
   input                   fifo_empty,
   output                  fifo_rd_en,

   output reg [WIDTH-1:0]  dout,
   output                  empty,
   input                   rd_en
);

   reg                     fifo_valid, middle_valid, dout_valid;
   reg [WIDTH-1:0]         middle_dout;

   wire                    will_update_middle, will_update_dout;

   // create FWFT FIFO out of non-FWFT FIFO
   // public domain code from Eli Billauer
   // see http://www.billauer.co.il/reg_fifo.html
   assign will_update_middle = fifo_valid && (middle_valid == will_update_dout);
   assign will_update_dout = (middle_valid || fifo_valid) && (rd_en || !dout_valid);
   assign fifo_rd_en = (!fifo_empty) && !(middle_valid && dout_valid && fifo_valid);
   assign empty = !dout_valid;

   always_ff @(posedge clk) begin
      if (rst) begin
         fifo_valid <= 0;
         middle_valid <= 0;
         dout_valid <= 0;
         dout <= 0;
         middle_dout <= 0;
      end else begin
         if (will_update_middle)
            middle_dout <= fifo_dout;

         if (will_update_dout)
            dout <= middle_valid ? middle_dout : fifo_dout;

         if (fifo_rd_en)
            fifo_valid <= 1;
         else if (will_update_middle || will_update_dout)
            fifo_valid <= 0;

         if (will_update_middle)
            middle_valid <= 1;
         else if (will_update_dout)
            middle_valid <= 0;

         if (will_update_dout)
            dout_valid <= 1;
         else if (rd_en)
            dout_valid <= 0;
      end
   end
endmodule
