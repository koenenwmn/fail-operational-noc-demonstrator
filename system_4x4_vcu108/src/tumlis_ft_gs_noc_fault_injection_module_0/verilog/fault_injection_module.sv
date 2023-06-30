/* Copyright (c) 2018 by the author(s)
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
 * This is a Fault Injection Module. When enabled, it flips a single bit of a
 * flit. The position of the flipped bit is determined by an internal counter.
 * Only a bit of a valid flit is flipped. This allows to selectively flip bits
 * of TDM traffic, but not BE traffic.
 *
 * Author(s):
 *   Andrea Nicholas Beretta <andrea.n.beretta@tum.de>
 */

module fault_injection_module #(
   parameter FLIT_WIDTH = 'x,
   localparam CNTR_MAX_VALUE = FLIT_WIDTH -1 
)(
   input clk,
   input rst,
   input enable,
   input flit_valid,

   input [FLIT_WIDTH-1:0]   in_flit,
   output [FLIT_WIDTH-1:0]  out_flit
);

   // Output value of the counter which is fed to the one-hot encoder
   reg [$clog2(FLIT_WIDTH)-1:0] cntr_val;

   // Output of the one-hot encoder. Has same size of in_flit
   wire [FLIT_WIDTH-1:0] one_hot_mask;

   // The internal counter for calculating the position of the bitflip
   always_ff @(posedge clk) begin
      if (rst) begin
         cntr_val <= {$clog2(FLIT_WIDTH){1'b0}};
      end else begin
         if (cntr_val == CNTR_MAX_VALUE) begin
            cntr_val <= {$clog2(FLIT_WIDTH){1'b0}};
         end else begin
            cntr_val <= cntr_val + 1'b1;
         end
      end
   end

   // One-hot encoding of counter value for XOR-module
   assign one_hot_mask = 1'b1 << cntr_val;

   // XOR the in_flit with the one_hot_mask
   assign out_flit = (enable & flit_valid) ? in_flit ^ one_hot_mask : in_flit;
endmodule  // fault_injection_module
