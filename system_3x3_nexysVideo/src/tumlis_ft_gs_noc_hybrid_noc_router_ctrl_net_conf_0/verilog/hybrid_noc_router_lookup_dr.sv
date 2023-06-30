/* Copyright (c) 2018-2021 by the author(s)
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
 * This is the lookup logic of the input port for the hybrid noc router with
 * distributed routing.
 * The module checks the next hop of a packet and requests the corresponding
 * output port of the router by setting the valid flag.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_router_lookup_dr #(
   parameter FLIT_WIDTH = 32,
   parameter PORTS = 5,
   parameter TABLE_WIDTH = 3,
   parameter LOCAL = 0,
   parameter DESTS = 'x,
   parameter [DESTS*TABLE_WIDTH-1:0] ROUTES = 'x,
   parameter DEST_WIDTH = 10,
   parameter DEST_POS = 0,
   parameter LINK_POS = 23 // Bit that determines which local link to use
)(
   input clk,
   input rst,

   input [FLIT_WIDTH-1:0]  in_flit,
   input                   in_valid,
   input                   in_last,
   output                  in_ready,

   output reg [FLIT_WIDTH-1:0]   out_flit,
   output [PORTS-1:0]            out_valid,
   output reg                    out_last,
   input [PORTS-1:0]             out_ready
);

   // Store current output port
   reg [PORTS-1:0]         out_valid_reg;

   // Keep track of valid output state
   reg                     out_is_valid;

   // Keep track of header
   reg                     is_header;

   // Keep track of discarding packet
   reg                     discarding;

   // Extract destination from in_flit
   wire [DEST_WIDTH-1:0]   dest;
   assign dest = in_flit[DEST_POS +: DEST_WIDTH];

   // Check if higher local port should be used
   wire                    local_high;
   assign local_high = (ROUTES[dest*TABLE_WIDTH +: TABLE_WIDTH] == LOCAL) & in_flit[LINK_POS];

   // Output stage is read
   wire                    read_out;
   assign read_out = |(out_valid & out_ready);
   // Output stage can be updated
   wire                    can_update;
   assign can_update = ~out_is_valid | read_out;
   // Discard a packet
   wire                    discard;
   assign discard = is_header & in_valid ? (dest >= DESTS) : discarding;
   // Output stage is updated
   wire                    update_out;
   assign update_out = in_valid & can_update & ~discard;
   // Update the valid register to request new output port
   wire                    update_valid_reg;
   assign update_valid_reg = update_out & is_header & ~discard;

   // Set output signals
   assign in_ready = can_update | discard;
   assign out_valid = out_is_valid ? out_valid_reg : 0;

   always_ff @(posedge clk) begin
      if (rst) begin
         out_is_valid <= 0;
         is_header <= 1;
         discarding <= 0;
      end else begin
         out_flit <= update_out ? in_flit : out_flit;
         out_last <= update_out ? in_last : out_last;
         out_valid_reg <= update_valid_reg ? 1'b1 << (ROUTES[dest*TABLE_WIDTH +: TABLE_WIDTH] + local_high) : out_valid_reg;
         discarding <= is_header ? discard : discarding;
         out_is_valid <= update_out | (out_is_valid & ~read_out);
         is_header <= in_ready & in_last | is_header & ~update_out;
      end
   end

endmodule // hybrid_noc_router_lookup_dr
