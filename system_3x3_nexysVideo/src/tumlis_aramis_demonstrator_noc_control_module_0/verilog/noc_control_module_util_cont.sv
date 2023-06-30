/* Copyright (c) 2019-2021 by the author(s)
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
 * This module collects the TDM and BE utilization of the links of each node.
 * It adds up the utilization over a given number of clock cycles and then sends
 * it to the host.
 * CLK_COUNTER_WIDTH must always be <= 32 bits.
 * The number of links a node can have is currently limited to 8 and a
 * MAX_DI_PKT_LEN of at least 12 is expected.
 *
 * This version of the module continuously sends out the collected utilization
 * every 'max_clk_counter' clock cycles. To achieve that without missing any any
 * results the module has a second set of registers causing a higher resource
 * cost than the record version.
 *
 * Author(s):
 *   Laura Grünauer
 *   Max Koenen <max.koenen@tum.de>
 */

import dii_package::dii_flit;

module noc_control_module_util_cont #(
   parameter MAX_DI_PKT_LEN   = 12,
   parameter X                = 3,
   parameter Y                = 3,
   localparam NODES                 = X * Y,
   localparam NUM_ACTIVE_LINKS      = X * Y * 8 - 2 * X - 2 * Y,
   localparam CLK_COUNTER_WIDTH     = 32, // other widths are currently not supported
   localparam TYPE_EVENT            = 2'b10,
   localparam TYPE_SUB_EVENT_LAST   = 4'b0000,
   // identifies the submodule
   localparam SUB_ID                      = 2'b01,
   // determines how many active links each node has (lower for edge nodes)
   localparam [NODES-1:0][3:0] NUM_LINKS  = num_links(),
   localparam [NODES*4-1:0] ACTIVE_LINKS  = active_links()
)(
   input                   clk, rst_noc, rst_debug, stall,
   input [15:0]            id,
   input [31:0]            max_clk_counter,
   input [15:0]            event_dest,
   // 8 Links for each node, 4 outputs between the routers, 2 output and 2 input
   // links to/from the compute tiles
   input [NODES-1:0][7:0]  tdm_util,
   input [NODES-1:0][7:0]  be_util,

   output dii_flit         util_out,
   input                   util_out_ready
);

   // ensure that parameters are set to allowed values
   initial begin
      if (MAX_DI_PKT_LEN < 12) begin
         $fatal("noc_control_module_util_cont: 'MAX_DI_PKT_LEN' must be at least 12.");
      end
   end

   // clk counter size depending on the clk counter width
   reg [CLK_COUNTER_WIDTH-1:0]      clk_counter;
   logic [CLK_COUNTER_WIDTH-1:0]    nxt_clk_counter;

   // each link needs CLK_COUNTER_WIDTH bits of memory, so the maximum of cycles
   // can BE stored
   reg [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]     tdm_save;
   logic [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]   nxt_tdm_save;
   reg [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]     be_save;
   logic [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]   nxt_be_save;

   // variables needed for the for loops
   logic [3:0]                link_counter;
   logic [$clog2(NODES):0]    n;
   logic [3:0]                l;

   // counters for the output FSM
   reg [$clog2(NODES)-1:0]    node_cnt;
   logic [$clog2(NODES)-1:0]  nxt_node_cnt;
   reg [3:0]                  link_cnt;
   logic [3:0]                nxt_link_cnt;


   // out vectors
   reg [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]     tdm_out;
   logic [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]   nxt_tdm_out;
   reg [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]     be_out;
   logic [NODES-1:0][7:0][CLK_COUNTER_WIDTH-1:0]   nxt_be_out;

   // send out flags to start the FSM
   reg                  send_ready;
   logic                nxt_send_ready;
   reg                  send_out;
   logic                nxt_send_out;

   // flag to signal, that a send out process is in progress and was interrupted
   reg                  save_out;
   logic                nxt_save_out;

   // flag, if TDM (= 00) or BE (= 01)
   reg [1:0]            trans_mode;
   logic [1:0]          nxt_trans_mode;

   // flag determining whether the lower or higher 16 bits of the link util are
   // sent out
   reg                  word;
   logic                nxt_word;

   always_ff @(posedge clk) begin
      if (rst_noc) begin
         clk_counter <= 0;
         send_ready <= 0;
         tdm_out <= 0;
         be_out <= 0;
         tdm_save <= 0;
         be_save <= 0;
      end else begin
         clk_counter <= nxt_clk_counter;
         send_ready <= nxt_send_ready;
         tdm_out <= nxt_tdm_out;
         be_out <= nxt_be_out;
         tdm_save <= nxt_tdm_save;
         be_save <= nxt_be_save;
      end
   end

   always_comb begin
      nxt_clk_counter = clk_counter + 1;
      nxt_send_ready = send_ready;
      nxt_tdm_out = tdm_out;
      nxt_be_out = be_out;
      nxt_tdm_save = tdm_save;
      nxt_be_save = be_save;

      // If the clk_counter is 'max_clk_counter', set a flag for the FSM to
      // start sending out the util data.
      // Write TDM/BE_save to the TDM/BE_out
      if (clk_counter >= max_clk_counter & ~stall) begin
         nxt_clk_counter = 0;
         nxt_send_ready = 1;
         if (!save_out) begin
            for (n = 0; n < NODES; n++) begin
               for (l = 0; l < NUM_LINKS[n]; l++) begin
                  nxt_tdm_out[n][l] = tdm_save[n][l];
                  nxt_be_out[n][l] = be_save[n][l];
               end
            end
         end
      end else begin
         nxt_send_ready = 0;
      end

      // The clk_counter counts for 'max_clk_counter' clk cycles.
      // Every clk cycle add the current value of TDM/BE_util to TDM/BE_save,
      // where each link is given a bitvector to store the accumulated value.
      // The active links are stored from TDM_save[node][0] to TDM_save[node][active_links-1].
      // The remaining vectors stay unused.

      // n represents the nodes, l represents the links
      for (n = 0; n < NODES; n++) begin
         link_counter = 0;
         for (l = 0; l < 8; l++) begin
            // only existing links are accumulated
            if (l < 4 && ACTIVE_LINKS[n*4+l] || l >= 4) begin
               // if the clk_counter runs out, replace TDM/BE_save with the current
               // TDM/BE_util value to start the accumulation again
               if (clk_counter >= max_clk_counter) begin
                  nxt_tdm_save[n][link_counter] = tdm_util[n][l];
                  nxt_be_save[n][link_counter] = be_util[n][l];
                  // if the clk_counter is != 0, accumulate
               end else begin
                  nxt_tdm_save[n][link_counter] = tdm_save[n][link_counter] + tdm_util[n][l];
                  nxt_be_save[n][link_counter] = be_save[n][link_counter] + be_util[n][l];
               end
               link_counter = link_counter + 1;
            end
         end
      end
   end

   // There are two always_clk and always_comb blocks at the moment, so if
   // we want to move the FSM to the toplevel, we can do that easily

   // Generating the Debug Packet
   enum   {IDLE, DEST, SRC, FLAGS, ID,
      XFER} state, nxt_state;

   always_ff @(posedge clk) begin
      if(rst_debug) begin
         state <= IDLE;
         send_out <= 0;
         save_out <= 0;
         link_cnt <= 0;
         node_cnt <= 0;
         trans_mode <= 0;
         word <= 0;
      end else begin
         state <= nxt_state;
         send_out <= nxt_send_out;
         save_out <= nxt_save_out;
         link_cnt <= nxt_link_cnt;
         node_cnt <= nxt_node_cnt;
         trans_mode <= nxt_trans_mode;
         word <= nxt_word;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_send_out = send_out;
      nxt_save_out = save_out;
      nxt_link_cnt = link_cnt;
      nxt_node_cnt = node_cnt;
      nxt_trans_mode = trans_mode;
      nxt_word = word;

      util_out.valid = 0;
      util_out.last = 0;
      util_out.data = 16'h0;

      if (send_ready || send_out) begin

         nxt_send_out = 1;
         // if the FSM is interrupted during a send out, the save out flag is
         // set to 1, so it is assured that the send out data is the same when
         // it proceeds
         case(state)
            IDLE: begin
               nxt_state = DEST;
            end
            DEST: begin
               util_out.valid = 1;
               util_out.data = event_dest;
               if (util_out_ready) begin
                  nxt_state = SRC;
               end else begin
                  nxt_save_out = 1;
               end
            end
            SRC: begin
               util_out.valid = 1;
               util_out.data = id;
               if (util_out_ready) begin
                  nxt_state = FLAGS;
               end else begin
                  nxt_save_out = 1;
               end
            end
            FLAGS: begin
               util_out.valid = 1;
               util_out.data = {TYPE_EVENT, TYPE_SUB_EVENT_LAST, 10'h0};
               if (util_out_ready) begin
                  nxt_state = ID;
               end else begin
                  nxt_save_out = 1;
               end
            end
            // one flit to verify the submodule, the node the transmission mode,
            // and the word that is sent
            ID: begin
               util_out.valid = 1;
               util_out.data = {node_cnt, word, trans_mode, SUB_ID};
               if (util_out_ready) begin
                  nxt_state = XFER;
               end else begin
                  nxt_save_out = 1;
               end
            end
            XFER: begin
               // send out the data in Debug Packets. Each Debug Packet contains
               // the  lower or higher 16 bits of the utilization data for all
               // links of one node. The size of the packets depends
               // on the number of active links. If there are more then 8 active
               // links to a node, this implementation has to be changed.
               // The first packet contains the lower 16 bits of the TDM util
               // data of all links of node 0. The next packet contains the
               // higher 16 bits of the TDM util data of that node. The last
               // packet contains the higher 16 bits of the BE util data of the
               // last node.
               util_out.valid = 1;
               if (util_out_ready) begin
                  if (trans_mode == 0) begin
                     if (word == 0) begin
                        util_out.data = tdm_out[node_cnt][link_cnt][15:0];
                     end else begin
                        util_out.data = tdm_out[node_cnt][link_cnt] >> 16;
                     end
                     if (link_cnt < NUM_LINKS[node_cnt]-1) begin
                        nxt_link_cnt = link_cnt + 1;
                     end else begin
                        nxt_link_cnt = 0;
                        nxt_state = DEST;
                        util_out.last = 1;
                        if (word == 0) begin
                           nxt_word = 1;
                        end else begin
                           nxt_word = 0;
                           // when TDM data is sent out, change to BE data
                           if (node_cnt == NODES-1) begin
                              nxt_node_cnt = 0;
                              nxt_trans_mode = 2'b01;
                           end else begin
                              nxt_node_cnt = node_cnt + 1;
                           end
                        end
                     end
                  end else begin
                     if (word == 0) begin
                        util_out.data = be_out[node_cnt][link_cnt][15:0];
                     end else begin
                        util_out.data = be_out[node_cnt][link_cnt] >> 16;
                     end
                     if (link_cnt < NUM_LINKS[node_cnt]-1) begin
                        nxt_link_cnt = link_cnt + 1;
                     end else begin
                        nxt_link_cnt = 0;
                        nxt_state = DEST;
                        util_out.last = 1;
                        if (word == 0) begin
                           nxt_word = 1;
                        end else begin
                           nxt_word = 0;
                           if (node_cnt == NODES-1) begin
                              nxt_node_cnt = 0;
                              nxt_trans_mode = 2'b00;
                              nxt_state = IDLE;
                              nxt_send_out = 0;
                              nxt_save_out = 0;
                           end else begin
                              nxt_node_cnt = node_cnt + 1;
                           end
                        end
                     end
                  end
               end else begin
                  nxt_save_out = 1;
               end
            end
         endcase
      end
   end

   // Create array with number of links for each node
   function bit [NODES-1:0][3:0] num_links();
      int n, x_dim, y_dim;
      for (n = 0; n < NODES; n++) begin
         x_dim = n % X;
         y_dim = n / X;
         num_links[n] = 8;
         if (x_dim == 0 || x_dim == X-1)
            num_links[n] = num_links[n] - 1;
         if (y_dim == 0 || y_dim == Y-1)
            num_links[n] = num_links[n] - 1;
      end
   endfunction

   // Create a bitvector defining the active links
   function bit [NODES*4-1:0] active_links();
      int n, x_dim, y_dim;
      active_links = {(NODES * 4){1'b0}};
      for (n = 0; n < NODES; n++) begin
         x_dim = n % X;
         y_dim = n / X;
         // Northern link
         active_links[n*4] = y_dim == 0 ? 1'b0 : 1'b1;
         // Eastern link
         active_links[n*4+1] = x_dim == X-1 ? 1'b0 : 1'b1;
         // Southern link
         active_links[n*4+2] = y_dim == Y-1 ? 1'b0 : 1'b1;
         // Western link
         active_links[n*4+3] = x_dim == 0 ? 1'b0 : 1'b1;
      end
   endfunction

endmodule // noc_control_modul_util_cont
