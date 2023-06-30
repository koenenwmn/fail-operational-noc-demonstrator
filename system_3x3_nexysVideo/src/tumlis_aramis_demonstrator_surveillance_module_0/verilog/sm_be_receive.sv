/* Copyright (c) 2020 by the author(s)
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
 * Extracts the valid source of a received BE packet.
 * The first two payload flits are checked for a correct data format. If either
 * one fails, the packet is faulty. After a successful reception of the whole
 * packet the valid or faulty signal is set.
 * A fault occurs if the first payload flit is not dest|dest or dest != TILEID
 * and the second payload flit is not src|src or the src >= NUM_TILES
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 */


module sm_be_receive #(
   parameter MAX_LEN = 8,
   parameter TILEID = 'x,
   parameter NUM_TILES = 'x,
   localparam MAX_WIDTH = $clog2(MAX_LEN+1),
   localparam TILE_WIDTH = $clog2(NUM_TILES)
)(
   input clk,
   input rst,

   input            enable,
   input [31:0]     data,
   output [TILE_WIDTH-1:0] src,
   output logic     faulty,
   output logic     valid
);
   enum {SIZE, ROUT, DEST, SRC, DRAIN} state, nxt_state;

   reg [MAX_WIDTH-1:0] rd_size;

   // keep track if there is already a faulty flit in the packet
   reg   cur_faulty;
   logic nxt_faulty;

   // store source to output it later
   reg [TILE_WIDTH-1:0]   cur_src;
   logic [TILE_WIDTH-1:0] nxt_src;

   assign src = cur_src;

   always_ff @(posedge clk) begin
      if (rst) begin
         state <= SIZE;
         cur_faulty <= 0;
         cur_src <= 0;
         rd_size <= 0;
      end else begin
         state <= nxt_state;
         cur_faulty <= nxt_faulty;
         cur_src <= nxt_src;
         if (enable & rd_size != 0) begin
             rd_size <= rd_size - 1;
         end else if(enable) begin
             rd_size <= data[MAX_WIDTH-1:0];
         end else begin
             rd_size <= rd_size;
         end
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_faulty = cur_faulty;
      nxt_src = cur_src;

      faulty = 1'b0;
      valid = 1'b0;
      if (enable) begin
         case (state)
            SIZE: begin
               // Read packet size
               // Check for size equals zero is necessary, as the core polls at
               // each endpoint, if a packet is available
               if (data[MAX_WIDTH-1:0] != 0) begin
                   nxt_state = ROUT;
               end
            end
            ROUT: begin
               // ignore header flit
               nxt_state = DEST;
            end
            DEST: begin
               // check if dest|dest and matches tileid
               if ((data[15:0] != data[31:16]) || (data[15:0] != TILEID)) begin
                  nxt_faulty = 1'b1;
               end
               nxt_state = SRC;
            end
            SRC: begin
               // check src|src and < NUM_TILES and extract source
               if ((data[15:0] != data[31:16]) || (data[15:0] >= NUM_TILES)) begin
                  nxt_faulty = 1'b1;
               end
               nxt_src = data[TILE_WIDTH-1:0];
               nxt_state = DRAIN;
            end
            DRAIN: begin
               // drain remaining flits
               if (rd_size == 1) begin
                  // output faulty or valid signal
                  faulty = cur_faulty;
                  valid = ~cur_faulty;
                  nxt_faulty = 1'b0;

                  nxt_state = SIZE;
               end
            end
         endcase
      end
   end

endmodule // sm_be_receive
