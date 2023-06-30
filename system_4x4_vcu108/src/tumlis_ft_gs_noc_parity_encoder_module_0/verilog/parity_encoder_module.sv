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
 * This is a Parity Encoder Module. It calculates the parity bits of the input
 * flit, combines them with the flit payload and sends the new flit to the
 * downstream instance. The module is purely combinatorial.
 *
 * Author(s):
 *   Andrea Nicholas Beretta <andrea.n.beretta@tum.de>
 */

module parity_encoder_module #(
   parameter FLIT_WIDTH = 'x,
   // The current number of bits/byte is hard coded to be 1
   localparam PARITY_BITS = FLIT_WIDTH/8 // numbers of parity bits of the flit
)(
   input [FLIT_WIDTH-1:0] in_flit,

   output [PARITY_BITS+FLIT_WIDTH-1:0] out_flit
);

   // Ensure that FLIT_WIDTH is set to multiple of 8
   initial begin
      if ((FLIT_WIDTH % 8) != 0 ) begin
         $fatal("noc_parity_encoder_module: FLIT_WIDTH must be set to a multiple of 8.");
      end
   end

   // Divide the flit into PARITY_BITS bytes
   wire [PARITY_BITS-1:0][7:0]   flit_bytes;

   // Wiring from the 8bit_parity_calc -> output
   wire [PARITY_BITS-1:0]        byte_parities;

   genvar b;
   generate 
      // Instantiate the 8bit parity calculators depending on the size of the flit
      for (b = 0; b < PARITY_BITS; b++) begin : calculators
         // Take 1 byte at a time and assign it to 'flit_bytes'
         assign flit_bytes[b] = in_flit[7+8*b:8*b];
         // Calculate parity on the single byte
         assign byte_parities[b] = ~^flit_bytes[b];
      end
   endgenerate

   // Stack the parity bits on top of the flit payload
   assign out_flit = {byte_parities, in_flit};
endmodule  // parity_encoder_module
