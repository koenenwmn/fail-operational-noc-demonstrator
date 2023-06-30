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
 * This module registers if an error occurs in one of the links, packs it to a
 * debug packet and sends the data to the debug interface every
 * 'max_clk_counter' cycles, but only if a new error occurs.
 *
 * Author(s):
 *   Laura Grünauer
 *   Max Koenen <max.koenen@tum.de>
 *
 */



import dii_package::dii_flit;

module noc_control_module_FD #(
   parameter MAX_DI_PKT_LEN = 12,
   // The size of the X*Y system must not exceed 18, as there are only 9 words
   // for sending the data. Otherwise this module has to be changed.
   parameter    X = 3,
   parameter    Y = 3,
   localparam   CLK_COUNTER_WIDTH = 32, // other widths are currently not supported
   localparam   NODES = X*Y,
   localparam   TYPE_EVENT          = 2'b10,
   localparam   TYPE_SUB_EVENT_LAST = 4'b0000,
   // identifies the submodule
   localparam   SUB_ID              = 2'b00,
   localparam   MAX_PAYLOAD_LEN     = MAX_DI_PKT_LEN - 4
)(
   input                   clk, rst_noc, rst_debug, stall,
   input [15:0]            id,
   input [31:0]            max_clk_counter,
   input [15:0]            event_dest,
   input [NODES-1:0][7:0]  faults_in,

   output dii_flit         faults_out,
   input                   fd_out_ready
);

   // ensure that parameters are set to allowed values
   initial begin
      if (X * Y > 18) begin
         $fatal("noc_control_module_FD: X * Y > 18 currently not supported.");
      end
   end

   reg [CLK_COUNTER_WIDTH:0]     clk_counter;
   logic [CLK_COUNTER_WIDTH:0]   nxt_clk_counter;

   reg [1:0][NODES-1:0][7:0]     reg_faults_in;
   logic [NODES-1:0][7:0]        nxt_reg_faults_in;

   reg                           flag_send_out;
   logic                         nxt_flag_send_out;
   reg [NODES-1:0][7:0]          reg_faults_out;
   logic [NODES-1:0][7:0]        nxt_reg_faults_out;

   reg [$clog2(NODES)-1:0]             counter;
   logic [$clog2(NODES)-1:0]           nxt_counter;
   reg [$clog2(MAX_PAYLOAD_LEN)-1:0]   payload_cnt;
   logic [$clog2(MAX_PAYLOAD_LEN)-1:0] nxt_payload_cnt;

   reg      start_out;
   logic    nxt_start_out;
   reg      send_out;
   logic    nxt_send_out;

   reg      save_out;
   logic    nxt_save_out;

    wire fault_update;
    assign fault_update = |(reg_faults_in[1] ^ reg_faults_in[0]);


   always_ff @(posedge clk) begin
      // counting to 'max_clk_counter' and detecting changes in faults
      if (rst_noc) begin
         reg_faults_in <= 0;
         flag_send_out <= 0;
         clk_counter <= 0;
         start_out <= 0;
         reg_faults_out <= 0;
      end else begin
         flag_send_out <= nxt_flag_send_out;
         clk_counter <= nxt_clk_counter;
         start_out <= nxt_start_out;
         reg_faults_in[1] <= reg_faults_in[0];
         reg_faults_in[0] <= faults_in;
         reg_faults_out <= nxt_reg_faults_out;
      end
   end

   always_comb begin
      nxt_flag_send_out = flag_send_out;
      nxt_clk_counter = clk_counter + 1;
      nxt_start_out = start_out;
      nxt_reg_faults_out = reg_faults_out;


      // comparing the new input faults vector with the saved faults vector,
      // if a change is detected, set a flag
      // also, if the clk counter runs out while a debug packet is sent out,
      // set the flag so the next round a packet is sent in every case.
      if ((fault_update) || (save_out && (clk_counter >= max_clk_counter & ~stall))) begin
         nxt_flag_send_out = 1;
      end else begin
         nxt_flag_send_out = flag_send_out;
      end


      // after every 'max_clk_counter' cycles and if the send_out flag is set, the
      // start_out flag is set if a fault occurred meanwhile.
      // Only if there is no other send out in progress, write the current
      // faults to the out register finally the counter is reset
      if (clk_counter >= max_clk_counter & ~stall) begin
         if (flag_send_out) begin
            nxt_start_out = 1;
            if (!save_out) begin
               nxt_reg_faults_out = reg_faults_in[1];
               if (~fault_update) begin
                  nxt_flag_send_out = 0;
               end
            end
         end
         nxt_clk_counter = 0;
      end else begin
         nxt_start_out = 0;
      end
   end


   // There are two always_clk and always_comb blocks at the moment, so if
   // we want to move the FSM to the toplevel, we can do that easily

   // Generating the Debug Packet
   enum   { STATE_IDLE, STATE_DEST, STATE_SRC, STATE_FLAGS, STATE_ID,
            STATE_XFER } state, nxt_state;

   always_ff @(posedge clk) begin
      if (rst_debug) begin
         state <= STATE_IDLE;
         counter <= 0;
         payload_cnt <= 0;
         send_out <= 0;
         save_out <= 0;
      end else begin
         state <= nxt_state;
         counter <= nxt_counter;
         payload_cnt <= nxt_payload_cnt;
         send_out <= nxt_send_out;
         save_out <= nxt_save_out;
      end
   end

   always_comb begin
      nxt_counter = counter;
      nxt_payload_cnt = payload_cnt;
      nxt_send_out = send_out;
      nxt_state = state;
      nxt_save_out = save_out;

      faults_out.valid = 0;
      faults_out.last = 0;
      faults_out.data = 16'h0;

      if (start_out || send_out) begin

         nxt_send_out = 1;
         case(state)
            STATE_IDLE: begin
               nxt_counter = 0;
               nxt_payload_cnt = 0;
               nxt_state = STATE_DEST;
            end
            STATE_DEST: begin
               faults_out.valid = 1;
               faults_out.data = event_dest;
               nxt_save_out = 1;
               if (fd_out_ready) begin
                  nxt_state = STATE_SRC;
               end
            end
            STATE_SRC: begin
               faults_out.valid = 1;
               faults_out.data = id;
               nxt_save_out = 1;
               if (fd_out_ready) begin
                  nxt_state = STATE_FLAGS;
               end
            end
            STATE_FLAGS: begin
               faults_out.valid = 1;
               faults_out.data = {TYPE_EVENT, TYPE_SUB_EVENT_LAST, 10'h0};
               nxt_save_out = 1;
               if (fd_out_ready) begin
                  nxt_state = STATE_ID;
               end
            end
            // one flit to verify the submodule
            STATE_ID: begin
               faults_out.valid = 1;
               faults_out.data = {counter, SUB_ID};
               nxt_save_out = 1;
               if (fd_out_ready) begin
                  nxt_state = STATE_XFER;
               end
            end
            STATE_XFER: begin
               faults_out.valid = 1;
               nxt_save_out = 1;
               if (fd_out_ready) begin
                  if (counter < NODES-1) begin
                     faults_out.data = {reg_faults_out[counter+1],
                                        reg_faults_out[counter]};
                     // Check if all nodes have been send out (in case of even number)
                     if (counter + 1 == NODES - 1) begin
                        faults_out.last = 1;
                        nxt_state = STATE_IDLE;
                        nxt_send_out = 0;
                        nxt_save_out = 0;
                     end else begin
                        // there are always 2 nodes sent out in one word
                        // --> counter + 2
                        nxt_counter = counter + 2;
                        if (payload_cnt == MAX_PAYLOAD_LEN - 1) begin
                           faults_out.last = 1;
                           nxt_payload_cnt = 0;
                           nxt_state = STATE_DEST;
                        end else begin
                           nxt_payload_cnt = payload_cnt + 1;
                        end
                     end
                  end else begin: last_output_flit
                     faults_out.data = {8'b0, reg_faults_out[counter]};
                     faults_out.last = 1;
                     nxt_state = STATE_IDLE;
                     nxt_send_out = 0;
                     nxt_save_out = 0;
                  end
               end
            end
         endcase
      end
   end

endmodule // noc_control_module_FD
