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
 * This module discards the first three flits of a DI packet that contain the
 * destination, source, and flags of the packet.
 * The module also combines event packets by only assigning the 'last' flag at
 * the last flit of the last event packet.
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Stefan Keller<stefan.keller@tum.de>
 */

import dii_package::dii_flit;

module discard_header(
   input                clk,
   input                rst,
   input dii_flit       in_flit,
   output logic         in_ready,

   output dii_flit      out_flit,
   input                out_ready
);

   reg                  last_event;
   logic                nxt_last_event;

   enum bit [1:0] {DEST, SRC, FLAGS, PAYLOAD} state, nxt_state;

   assign in_ready = state == PAYLOAD ? out_ready : 1;
   assign out_flit.valid = state == PAYLOAD ? in_flit.valid : 0;
   assign out_flit.data = state == PAYLOAD ? in_flit.data : 0;
   assign out_flit.last = (state == PAYLOAD) && last_event ? in_flit.last : 0;

   always @(posedge clk) begin
      if (rst) begin
         state <= DEST;
         last_event <= 0;
      end else begin
         state <= nxt_state;
         last_event <= nxt_last_event;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_last_event = last_event;

      case (state)
         DEST: begin
            if (in_flit.valid) begin
               nxt_state = SRC;
            end
         end
         SRC: begin
            if (in_flit.valid) begin
               nxt_state = FLAGS;
            end
         end
         FLAGS: begin
            if (in_flit.valid) begin
               // check if packet is a last event packet
               if (in_flit.data[13:10] == 4'b0001) begin
                  nxt_last_event = 1'b0;
               end else begin
                  nxt_last_event = 1'b1;
               end
               nxt_state = PAYLOAD;
            end
         end
         PAYLOAD: begin
            if (in_flit.valid & in_flit.last & out_ready) begin
               nxt_state = DEST;
            end
         end
      endcase
   end

endmodule
