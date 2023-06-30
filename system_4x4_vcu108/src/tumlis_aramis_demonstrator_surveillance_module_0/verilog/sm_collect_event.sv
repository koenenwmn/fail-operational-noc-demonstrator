/* Copyright (c) 2020-2021 by the author(s)
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
 * Collects number of packets sent to or received from each tile(BE)/channel(TDM).
 * If clk_counter exceeds MAX_CLK_COUNT a debug packet with the current data is
 * generated.
 * If the module is stalled the accumulators and clk_counter keep their current
 * values. Hence no new debug packet is created. Note: If a debug packet is in
 * transmission while the module gets stalled, the transmission will still
 * complete.
 *
 * -----------------------------------------------------------------------------
 *
 * Dii payload sequence: (16-bit per flit)
 * {num_packets to channel 0 word 0}
 * {num_packets to channel 0 word 1}
 * {num_packets to channel 1 word 0}
 * ...
 * {num_packets from/to tile/channel idx word 1}
 * {num_packets from/to tile/channel idx+1 word 0}
 * ...
 * {num_packets from tile NUM_TILES-1 word 1}
 * {num_packets faulty}
 *
 * The values (32-bit) of each accumulator is sent in two payload flits (16-bit)
 * The first word is bits 0:15 and the second is bits 16:31.
 * The order is TDMSEND, TDMRECV, BESEND, BERECV and eventually FAULTY.
 * The host has to keep track of the payload!
 *
 * MODE:
 * TDMSEND = 3'h0
 * TDMRECV = 3'h1
 * BESEND = 3'h2
 * BERECV = 3'h3
 * FAULTY = 3'h4
 *
 * =============================================================================
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 */


import dii_package::dii_flit;

module sm_collect_event #(
   parameter NUM_TDM_ENDPOINTS = 4,
   parameter NUM_TILES = 9,
   parameter TILEID = 'x,
   parameter MAX_DI_PKT_LEN = 12,
   localparam TILE_WIDTH = $clog2(NUM_TILES),
   localparam ENDP_WIDTH = $clog2(NUM_TDM_ENDPOINTS),
   localparam MAX_DI_PKT_LEN_WIDTH = $clog2(MAX_DI_PKT_LEN),
   localparam MAX_IDX_WIDTH = (TILE_WIDTH > ENDP_WIDTH ? TILE_WIDTH : ENDP_WIDTH)
)(
   input clk,
   input rst_dbg,
   input rst_sys,

   input [15:0] id,
   input [15:0] event_dest,

   output dii_flit         dii_out_flit,
   input                   dii_out_flit_ready,

   input [TILE_WIDTH-1:0]  dest_be,
   input [TILE_WIDTH-1:0]  src_be,
   input [ENDP_WIDTH-1:0]  dest_tdm,
   input [ENDP_WIDTH-1:0]  src_tdm,
   input                   valid_be_send,
   input                   valid_be_recv,
   input                   valid_tdm_send,
   input                   valid_tdm_recv,
   input                   faulty,

   input [31:0]            max_clk_counter // received from sm_config
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (MAX_DI_PKT_LEN < 4) begin
         $fatal("Debug packets to small, no payload can be transmitted");
      end
      if (TILEID >= NUM_TILES) begin
         $fatal("TILEID must be < NUM_TILES");
      end
   end


   wire        stall;
   assign stall = ~|max_clk_counter;
   reg [31:0]  clk_counter;
   reg         gen_event;

   reg [NUM_TDM_ENDPOINTS-1:0][31:0]   tdm_send;
   reg [NUM_TDM_ENDPOINTS-1:0][31:0]   tdm_recv;
   reg [NUM_TILES-1:0][31:0]           be_send;
   reg [NUM_TILES-1:0][31:0]           be_recv;
   reg [31:0]                          reg_faulty;

   reg [NUM_TDM_ENDPOINTS-1:0][31:0]   tdm_send_out;
   reg [NUM_TDM_ENDPOINTS-1:0][31:0]   tdm_recv_out;
   reg [NUM_TILES-1:0][31:0]           be_send_out;
   reg [NUM_TILES-1:0][31:0]           be_recv_out;
   reg [31:0]                          out_faulty;

   // loop variable
   logic [MAX_IDX_WIDTH:0] i;

   // collect statistics
   always_ff @(posedge clk) begin
      if (rst_sys) begin
         clk_counter <= 0;
         gen_event <= 0;

         tdm_send <= 0;
         tdm_recv <= 0;
         be_send <= 0;
         be_recv <= 0;
         reg_faulty <= 0;
      end else begin
         if(~stall) begin
            if(clk_counter >= max_clk_counter) begin
               // time for new debug messages, set output values
               // and reset accumulation
               clk_counter <= 0;
               gen_event <= 1;

               // set output
               for (i = 0; i < NUM_TDM_ENDPOINTS; i++) begin
                  tdm_send_out[i] <= tdm_send[i] + ((dest_tdm == i) ? valid_tdm_send : 0);
                  tdm_recv_out[i] <= tdm_recv[i] + ((src_tdm == i) ? valid_tdm_recv : 0);
               end
               for (i = 0; i < NUM_TILES; i++) begin
                  be_send_out[i] <= be_send[i] + ((dest_be == i) ? valid_be_send : 0);
                  be_recv_out[i] <= be_recv[i] + ((src_be == i) ? valid_be_recv : 0);
               end
               out_faulty <= reg_faulty + faulty;

               // reset
               tdm_send <= 0;
               tdm_recv <= 0;
               be_send <= 0;
               be_recv <= 0;
               reg_faulty <= 0;
            end else begin
               clk_counter <= clk_counter + 1;
               gen_event <= 0;

               tdm_send[dest_tdm] <= tdm_send[dest_tdm] + valid_tdm_send;
               tdm_recv[src_tdm] <= tdm_recv[src_tdm] + valid_tdm_recv;
               be_send[dest_be] <= be_send[dest_be] + valid_be_send;
               be_recv[src_be] <= be_recv[src_be] + valid_be_recv;
               reg_faulty <= reg_faulty + faulty;
            end
         end else
            gen_event <= 0;
      end
   end

   // create debug packet FSM
   enum {DEST, SRC, FLAGS, XFER} state, nxt_state;

   localparam TDMSEND = 3'h0;
   localparam TDMRECV = 3'h1;
   localparam BESEND = 3'h2;
   localparam BERECV = 3'h3;
   localparam FAULTY = 3'h4;

   // distinguish between tdm/be and send/recv
   reg [2:0]   mode;
   logic [2:0] nxt_mode;

   // flag if FSM is running
   reg   sending;
   logic nxt_sending;

   // first or second half of data
   reg   word;
   logic nxt_word;

   // counter to keep track of src/dest
   reg [MAX_IDX_WIDTH-1:0]   idx;
   logic [MAX_IDX_WIDTH-1:0] nxt_idx;

   // counter to determine when a packet is full
   reg [MAX_DI_PKT_LEN_WIDTH-1:0]   flit_cnt;
   logic [MAX_DI_PKT_LEN_WIDTH-1:0] nxt_flit_cnt;

   always_ff @(posedge clk) begin
      if (rst_dbg) begin
         state <= DEST;
         mode <= TDMSEND;
         sending <= 0;
         word <= 0;
         idx <= 0;
         flit_cnt <= 0;
      end else begin
         state <= nxt_state;
         mode <= nxt_mode;
         sending <= nxt_sending;
         word <= nxt_word;
         idx <= nxt_idx;
         flit_cnt <= nxt_flit_cnt;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_mode = mode;
      nxt_sending = sending;
      nxt_word = word;
      nxt_idx = idx;
      nxt_flit_cnt = flit_cnt;

      dii_out_flit.data = 0;
      dii_out_flit.valid = 0;
      dii_out_flit.last = 0;

      if (gen_event || sending) begin
         nxt_sending = 1;

         case (state)
            // dii header
            DEST: begin
               dii_out_flit.valid = 1;
               dii_out_flit.data = event_dest;
               if (dii_out_flit_ready) begin
                  nxt_state = SRC;
               end
            end
            SRC: begin
               dii_out_flit.valid = 1;
               dii_out_flit.data = id;
               if (dii_out_flit_ready) begin
                  nxt_state = FLAGS;
               end
            end
            FLAGS: begin
               dii_out_flit.valid = 1;
               dii_out_flit.data = {2'b10, 4'b0, 10'h0}; //TYPE_EVENT, TYPE_SUB_EVENT_LAST
               if (dii_out_flit_ready) begin
                  nxt_state = XFER;
               end
            end
            XFER: begin
               dii_out_flit.valid = 1;
               dii_out_flit.last = flit_cnt == MAX_DI_PKT_LEN - 4 ? 1 : 0;
               if (dii_out_flit_ready) begin
                  // Check if packet is full
                  if (flit_cnt == MAX_DI_PKT_LEN - 4) begin
                     nxt_flit_cnt = 0;
                     nxt_state = DEST;
                  end else begin
                     nxt_flit_cnt = flit_cnt + 1;
                  end
                  // Determine what data to send out
                  case (mode)
                     TDMSEND: begin
                        dii_out_flit.data = word ? tdm_send_out[idx][31:16] : tdm_send_out[idx][15:0];
                        nxt_word = word + 1; // toggle word
                        if (word == 1) begin
                           if (idx == NUM_TDM_ENDPOINTS - 1) begin
                              nxt_mode = TDMRECV;
                              nxt_idx = 0;
                           end else begin
                              nxt_idx = idx + 1; // increase idx
                           end
                        end
                     end
                     TDMRECV: begin
                        dii_out_flit.data = word ? tdm_recv_out[idx][31:16] : tdm_recv_out[idx][15:0];
                        nxt_word = word + 1; // toggle word
                        if (word == 1) begin
                           if (idx == NUM_TDM_ENDPOINTS - 1) begin
                              nxt_mode = BESEND;
                              nxt_idx = 0;
                           end else begin
                              nxt_idx = idx + 1; // increase idx
                           end
                        end
                     end
                     BESEND: begin
                        dii_out_flit.data = word ? be_send_out[idx][31:16] : be_send_out[idx][15:0];
                        nxt_word = word + 1; // toggle word
                        if (word == 1) begin
                           if (idx == NUM_TILES - 1) begin
                              nxt_mode = BERECV;
                              nxt_idx = 0;
                           end else begin
                              nxt_idx = idx + 1; // increase idx
                           end
                        end
                     end
                     BERECV: begin
                        dii_out_flit.data = word ? be_recv_out[idx][31:16] : be_recv_out[idx][15:0];
                        nxt_word = word + 1; // toggle word
                        if (word == 1) begin
                           if (idx == NUM_TILES - 1) begin
                              nxt_mode = FAULTY;
                              nxt_idx = 0;
                           end else begin
                              nxt_idx = idx + 1; // increase idx
                           end
                        end
                     end
                     FAULTY: begin
                        dii_out_flit.data = word ? out_faulty[31:16] : out_faulty[15:0];
                        nxt_word = word + 1; // toggle word
                        if (word == 1) begin
                           // last word, transmission completed
                           nxt_mode = TDMSEND;
                           dii_out_flit.last = 1;
                           nxt_flit_cnt = 0;
                           nxt_state = DEST;
                           nxt_sending = 0;
                        end
                     end
                     default: begin
                        // should not happen
                        nxt_state = DEST;
                        nxt_mode = TDMSEND;
                        nxt_sending = 0;
                        nxt_word = 0;
                        nxt_idx = 0;
                        nxt_flit_cnt = 0;
                     end
                  endcase
               end
            end
         endcase
      end
   end

endmodule // sm_collect_event
