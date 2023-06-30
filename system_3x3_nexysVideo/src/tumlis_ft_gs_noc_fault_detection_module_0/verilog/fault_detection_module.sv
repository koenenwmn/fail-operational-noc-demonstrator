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
 * This is a Fault Detection Module. It computes the parity bits of the input
 * flit and compares with it with the received parity bitvector over the PHY
 * link, thus signaling when a fault occurs in the network
 *
 * Author(s):
 *   Andrea Nicholas Beretta <andrea.n.beretta@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module fault_detection_module #(
   parameter FLIT_WIDTH = 'x,
   parameter ROUTER_STAGES = 2,
   parameter FAULTS_PERMANENT = 0,
   localparam NUMBYTES = FLIT_WIDTH/8 // numbers of bytes in a flit
)(
   input clk,
   input rst,
   
   input [FLIT_WIDTH-1:0]   in_flit,
   input                    in_valid,
   input [NUMBYTES-1:0]     in_parity,
   
   output                   out_error
);

   // Ensure that FLIT_WIDTH is set to multiple of 8
   initial begin
      if ((FLIT_WIDTH % 8) != 0 ) begin
         $fatal("fault_detection_module: FLIT_WIDTH must be set to a multiple of 8.");
      end else if (ROUTER_STAGES != 1 && ROUTER_STAGES != 2) begin
         $fatal("fault_detection_module: ROUTER_STAGES must be set to '1' or '2'.");
      end
   end

   // Divide the flit into NUMBYTES bytes
   wire [NUMBYTES-1:0][7:0]   flit_bytes;

   // Wiring from the 8bit_parity_calc -> XOR-gate
   wire [NUMBYTES-1:0]        byte_parities;

   // Wiring from  OR-gate -> register
   wire                       parity_check;
   wire                       nxt_reg_out_error;

   // Wiring from the XOR-gate -> OR-gate
   wire [NUMBYTES-1:0]        compared_parity;

   // Wiring from register -> output
   reg                        reg_out_error;

   genvar b;
   generate 
      // Instantiate the 8bit parity calculators depending on the size of the flit
      for (b = 0; b < NUMBYTES; b++) begin : calculators
         // Take 1 byte at a time and assign it to 'flit_bytes'
         assign flit_bytes[b] = in_flit[7+8*b:8*b];
         // Calculate parity on the single byte
         assign byte_parities[b] = ~^flit_bytes[b];
         // 1bit XOR operation between the calculated parity 'byte_parities' and
         // 'in_parity'. If same, it means that the parity check is OK
         assign compared_parity[b] = (byte_parities[b] ^ in_parity[b]);
      end
   endgenerate

   // Bitwise OR on the 'compared_parity' vector
   assign parity_check = |compared_parity;

   generate
      if (FAULTS_PERMANENT != 0) begin
         assign nxt_reg_out_error = parity_check | reg_out_error;
      end else begin
         assign nxt_reg_out_error = parity_check;
      end
   endgenerate

   // In case of one router stage the error will be forwarded immediately.
   // Otherwise the error will be forwarded with the next rising clk edge.
   generate
      if (ROUTER_STAGES == 1) begin
         assign out_error = in_valid ? nxt_reg_out_error : reg_out_error;
      end else if (ROUTER_STAGES == 2) begin
         assign out_error = reg_out_error;
      end
   endgenerate

   always_ff @(posedge clk) begin
      if (rst) begin
         reg_out_error <= 0;
      end else begin
         if (in_valid) begin
            reg_out_error <= nxt_reg_out_error;
         end else begin
            reg_out_error <= reg_out_error;
         end
      end
   end
endmodule  // fault_detection_module
