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
 * Extracts the valid destination of a TDM packet
 * The valid signal is set when the first flit is processed (not after sending
 * is complete), as there is no error handling for tdm packets and that way
 * the complexity is reduced.
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 */


module sm_tdm_send #(
   parameter MAX_LEN = 8,
   parameter NUM_TDM_ENDPOINTS = 4,
   localparam MAX_WIDTH = $clog2(MAX_LEN+1),
   localparam ENDP_WIDTH = $clog2(NUM_TDM_ENDPOINTS)
)(
   input clk,
   input rst,

   input                   enable,
   input [31:0]            data,
   input [ENDP_WIDTH-1:0]  ep,
   output [ENDP_WIDTH-1:0] dest,
   output logic            valid
);
   enum {SIZE, DRAIN} state, nxt_state;

   reg [MAX_WIDTH-1:0]     wr_size;

   assign dest = ep;

   always_ff @(posedge clk) begin
      if (rst) begin
         state <= SIZE;
         wr_size <= 0;
      end else begin
         state <= nxt_state;
         if (enable & wr_size != 0) begin
            wr_size <= wr_size - 1;
         end else if(enable) begin
            wr_size <= data[MAX_WIDTH-1:0];
         end else begin
            wr_size <= wr_size;
         end
      end
   end

   always_comb begin
      nxt_state = state;
      valid = 1'b0;
      if (enable) begin
         case (state)
            SIZE: begin
               // Read packet size
               valid = 1'b1;
               nxt_state = DRAIN;
            end
            DRAIN: begin
               // drain payload
               if (wr_size == 1) begin
                  nxt_state = SIZE;
               end
            end
         endcase
      end
   end

endmodule // sm_tdm_send
