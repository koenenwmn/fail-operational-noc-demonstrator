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
 * The module reads 16-bit packets and forwards a full packet to the packetizer
 * to be sent out via the DI. The packetizer will divide the packet into
 * multiple DI packets if necessary.
 *
 * Author(s):
 *   Stefan Keller <stefan.keller@tum.de>
 */

import dii_package::dii_flit;

module di_na_bridge_packetizer #(
   parameter MAX_PKT_LEN = 12,         // The maximum length of a DI packet in flits, including the header flits
   parameter MAX_DATA_NUM_WORDS = 12,  // The maximum number of payload flits belonging together

   localparam CNT_W = $clog2(MAX_DATA_NUM_WORDS + 1)
)(
   input             clk,
   input             rst,

   output dii_flit   debug_out,
   input             debug_out_ready,

   // DI address of this module (SRC)
   input [15:0]      id,

   // DI address of the event destination (DEST)
   input [15:0]      dest,

   input [15:0]      out_flit_data,
   input             out_flit_valid,
   input             out_flit_last,
   output            out_flit_ready
);
   reg [CNT_W-1:0]   num_data_words;
   logic [CNT_W-1:0] nxt_num_data_words;

   wire [15:0]       buf_flit_data;
   wire              buf_flit_valid;
   wire              buf_flit_ready;
   wire [CNT_W-1:0]  packet_size;
   wire              data_req_valid;
   wire              event_consumed;

   assign buf_flit_ready = data_req_valid & debug_out_ready;

   enum {IDLE, READ} state, nxt_state;

   always @(posedge clk) begin
      if (rst) begin
         state <= IDLE;
         num_data_words <= 0;
      end else begin
         state <= nxt_state;
         num_data_words <= nxt_num_data_words;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_num_data_words = num_data_words;

      case (state)
         IDLE: begin
            nxt_num_data_words = packet_size;
            if (buf_flit_ready) begin
               nxt_state = READ;
            end
         end

         READ: begin
            if (event_consumed) begin
               nxt_state = IDLE;
            end
         end
      endcase
   end

   noc_buffer #(
      .FLIT_WIDTH (16),
      .DEPTH      (1 << $clog2(MAX_DATA_NUM_WORDS)),
      .FULLPACKET (1))
   u_16_bit_noc_buffer(
      .clk           (clk),
      .rst           (rst),
      .in_flit       (out_flit_data),
      .in_valid      (out_flit_valid),
      .in_last       (out_flit_last),
      .in_ready      (out_flit_ready),

      .out_flit      (buf_flit_data),
      .out_valid     (buf_flit_valid),
      .out_last      (),
      .out_ready     (buf_flit_ready),
      .packet_size   (packet_size)
   );

   osd_event_packetization #(
      .MAX_PKT_LEN         (MAX_PKT_LEN),
      .MAX_DATA_NUM_WORDS  (MAX_DATA_NUM_WORDS))
   u_packetization(
      .clk              (clk),
      .rst              (rst),
      .debug_out        (debug_out),
      .debug_out_ready  (debug_out_ready),
      .id               (id),
      .dest             (dest),
      .overflow         (0),
      .event_available  (buf_flit_valid),
      .event_consumed   (event_consumed),

      .data_num_words   (num_data_words),
      .data_req_valid   (data_req_valid),
      .data_req_idx     (),
      .data             (buf_flit_data)
   );

endmodule
