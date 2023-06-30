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
 * This is the slot table (or LUT) for each output port of a router. It
 * determines the routing of TDM flits.
 * This version of the slot table is configured via a dedicated control network.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module tdm_noc_slot_table #(
   parameter PORTS = 'x,
   parameter LUT_SIZE = 16,
   parameter OUTPUT_ID = 'x
)(
   input    clk,
   input    rst,
   output reg [$clog2(PORTS+1)-1:0] select,

   // Interface for writing to LUT.
   // Each output port has it's own LUT determining which input to forward.
   input [$clog2(PORTS+1)-1:0]      lut_conf_data,
   input [$clog2(PORTS)-1:0]        lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]     lut_conf_slot,
   input                            lut_conf_valid
);

   // Ensure that parameters are set to allowed values
   initial begin
      if ((1 << $clog2(LUT_SIZE)) != LUT_SIZE) begin
         $fatal("tdm_noc_slot_table: the LUT_SIZE must be a power of two.");
      end
   end


   reg [LUT_SIZE-1:0][$clog2(PORTS+1)-1:0]   lut;
   reg [$clog2(LUT_SIZE)-1:0]                lut_ptr;

   always_ff @(posedge clk) begin
      if (rst) begin
         lut_ptr <= 0;
         select <= '1;
      end else begin
         lut_ptr <= lut_ptr + 1'b1;
         select <= lut[lut_ptr];
      end
   end

   // Write to LUT
   always_ff @(posedge clk) begin
      if (rst) begin
         lut <= {LUT_SIZE*$clog2(PORTS+1){1'b1}};
      end else if (lut_conf_valid && lut_conf_sel == OUTPUT_ID) begin
         // Does not check if configuration is valid
         lut[lut_conf_slot] <= lut_conf_data;
      end
   end

endmodule // tdm_noc_slot_table
