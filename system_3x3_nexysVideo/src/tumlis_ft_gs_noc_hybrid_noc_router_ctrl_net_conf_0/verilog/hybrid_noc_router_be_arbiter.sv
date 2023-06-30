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
 *
 * This is the arbiter for the best effort traffic. It is instantiated in each
 * output port and serves each input port in a round-robin fashion.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_router_be_arbiter #(
   parameter PORTS = 'x
)(
   input    clk,
   input    rst,

   input [PORTS-1:0]             in_valid,
   input [PORTS-1:0]             in_last,
   output logic [PORTS-1:0]      in_ready,

   input                         buffer_ready,
   output logic                  buffer_valid,
   output                        buffer_last,
   output [$clog2(PORTS)-1:0]    select
);

   reg [PORTS-1:0]               gnt;        // Current grant, one hot
   wire [PORTS-1:0]              nxt_gnt;    // Next grant, one hot
   logic [$clog2(PORTS)-1:0]     nxt_select; // Next select, binary
   assign select = nxt_select;

   // Determines if any input has been granted access.
   reg active_gnt;
   logic nxt_active_gnt;

   wire [PORTS-1:0] req_masked;
   assign req_masked = {PORTS{~active_gnt & buffer_ready}} & in_valid;

   assign buffer_last = in_last[nxt_select];

   always_comb begin
      nxt_active_gnt = active_gnt;
      in_ready = {PORTS{1'b0}};

      if (active_gnt) begin
         if (|(in_valid & gnt)) begin
            buffer_valid = 1;
            if (buffer_ready) begin
               in_ready = gnt;
               if (buffer_last)
                  nxt_active_gnt = 0;
            end
         end else begin
            buffer_valid = 1'b0;
         end
      end else begin
         buffer_valid = 0;
         if (|in_valid && buffer_ready) begin
            buffer_valid = 1'b1;
            nxt_active_gnt = ~buffer_last;
            in_ready = nxt_gnt;
         end
      end
   end

   always_ff @(posedge clk) begin
      if (rst) begin
         active_gnt <= 0;
         gnt <= {{PORTS-1{1'b0}},1'b1};
      end else begin
         active_gnt <= nxt_active_gnt;
         gnt <= nxt_gnt;
      end
   end

   // The round-robin arbiter logic (purely combinatorial)
   arb_rr #(
      .N(PORTS))
   u_arb_comb(
      .req     (req_masked),
      .en      (1'b1),
      .gnt     (gnt),
      .nxt_gnt (nxt_gnt)
   );

   // One hot to binary
   always_comb begin
      logic [$clog2(PORTS):0] i;
      nxt_select = 0;
      for (i = 0; i < PORTS; i++) begin
         if (nxt_gnt[i])
            nxt_select = i;
      end
   end

endmodule // hybrid_noc_router_be_arbiter
