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
 * This module processes the fault injection that is executed by the host.
 * It extracts the relevant information and sends it to the addressed module.
 *
 * Author(s): Laura Grünauer
 *
 */



import dii_package::dii_flit;

module noc_control_module_FI #(
   parameter    X = 3,
   parameter    Y = 3,
   localparam   NODES = X*Y
)(
   input                         clk, rst,
   input dii_flit                flit_in,
   output reg [NODES-1:0][7:0]   fim_en
);

   logic [7:0]                links;
   logic [7:0]                nodes;

   logic [NODES-1:0][7:0]     nxt_fim_en;


   always_ff @(posedge clk) begin
      if(rst) begin
         fim_en <= 0;
      end else begin
         fim_en <= nxt_fim_en;
      end
   end

   always_comb begin
      nodes = 0;
      links = 0;

      nxt_fim_en = fim_en;
      // check if the flit is valid
      if (flit_in.valid == 1) begin
            nodes = flit_in.data[15:8];
            links = flit_in.data[7:0];
            nxt_fim_en[nodes] = links;
      end
   end

endmodule // noc_control_module_FI
