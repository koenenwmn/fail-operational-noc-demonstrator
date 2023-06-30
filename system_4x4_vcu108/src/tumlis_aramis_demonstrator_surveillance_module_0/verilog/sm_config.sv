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
 * Write registers to configure tile, rise core irq if register changes
 * and core can fetch new values.
 * Registers:
 *  - REG_ADDR: First read from this address to get address to read from next
 *  - REG_XYDIM: The x-dim|y-dim of the noc
 *  - REG_MINBURST
 *  - REG_MAXBURST
 *  - REG_MINDELAY
 *  - REG_MAXDELAY
 *  - ...
 *  - REG_LOT_BASE: The base address for configuring a list of tiles.
 *                  A set bit means, that the core should send messages to that
 *                  tile, e.g. bit 2 and 1 are set (0x0006) --> send to tile 2
 *                  and 1. If there are more than 32 tiles, REG_LOT_BASE+1 can
 *                  be used. Hence bit 0 of 0x401 sets tile 33.
 *
 * This module also provides a way to configure the module itself
 * (only accessible from debug side)
 *  - REG_MAXCLKCNT: max_clk_counter_reg: set the period, after which a event
 *                                         should be generated
 *  - ...
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 *   Thomas Hallermeier <thomas.hallermeier@tum.de>
 */

import dii_package::dii_flit;

module sm_config #(
   parameter NUM_TILES = 9,
   localparam MAX_REG_SIZE = 32,
   localparam NUM_LOT_REG = ((NUM_TILES-1)/32)+1
)(
   input clk,
   input rst,

   input dii_flit       dii_flit_in,

   input [31:0]         wb_addr,
   input                wb_cyc,
   input [31:0]         wb_data_in, // unused
   input [3:0]          wb_sel,     // unused
   input                wb_stb,
   input                wb_we,
   input                wb_cab,     // unused
   input [2:0]          wb_cti,     // unused
   input [1:0]          wb_bte,     // unused
   output logic         wb_ack,
   output logic         wb_rty,     // unused
   output logic         wb_err,
   output logic [31:0]  wb_data_out,

   output [31:0]  max_clk_counter,
   output         irq
);
   assign wb_rty = 1'b0;

   // Register addresses
   // First read this register to get address to read from
   localparam REG_ADDR = 12'h000;

   // module specific register
   localparam REG_MAXCLKCNT = 12'h200;

   // core configuration
   localparam REG_XYDIM =    12'h300;
   localparam REG_MINBURST = 12'h304;
   localparam REG_MAXBURST = 12'h308;
   localparam REG_MINDELAY = 12'h30c;
   localparam REG_MAXDELAY = 12'h310;
   localparam REG_SEED =     12'h314;

   localparam REG_LOT_BASE = 12'h400;


   // Register to store next address to read from
   logic [11:0] read_addr;

   // Module specific registers
   reg [31:0] max_clk_counter_reg;
   assign max_clk_counter = max_clk_counter_reg;

   // Core specific registers and dirty flags
   reg [31:0] xy_dim; //bit 31:16: x_dim, 15:0: y_dim
   reg [31:0] min_burst;
   reg [31:0] max_burst;
   reg [31:0] min_delay;
   reg [31:0] max_delay;
   reg [31:0] seed;
   reg [NUM_LOT_REG-1:0][31:0] lot;

   reg xy_dim_dirty;
   reg min_burst_dirty;
   reg max_burst_dirty;
   reg min_delay_dirty;
   reg max_delay_dirty;
   reg seed_dirty;
   reg [NUM_LOT_REG-1:0] lot_dirty;

   logic nxt_xy_dim_dirty;
   logic nxt_min_burst_dirty;
   logic nxt_max_burst_dirty;
   logic nxt_min_delay_dirty;
   logic nxt_max_delay_dirty;
   logic nxt_seed_dirty;
   logic [NUM_LOT_REG-1:0] nxt_lot_dirty;


   // Debug Event packet FSM states and registers
   enum {STATE_ADDR, STATE_LOW_WORD, STATE_HIGH_WORD, STATE_DRAIN} state;
   reg [11:0]     reg_addr;
   reg [15:0]     wr_data_low_word;
   wire [31:0]    wr_data;
   assign wr_data = {dii_flit_in.data, wr_data_low_word};

   // loop variables
   logic [$clog2(NUM_LOT_REG):0] n;
   logic [$clog2(NUM_LOT_REG):0] m;

   always_ff @(posedge clk) begin
      if (rst) begin
         max_clk_counter_reg <= 0;
         xy_dim <= 0;
         min_burst <= 0;
         max_burst <= 0;
         min_delay <= 0;
         max_delay <= 0;
         seed <= 0;
         lot <= 0;

         xy_dim_dirty <= 0;
         min_burst_dirty <= 0;
         max_burst_dirty <= 0;
         min_delay_dirty <= 0;
         max_delay_dirty <= 0;
         seed_dirty <= 0;
         lot_dirty <= 0;

         state <= STATE_ADDR;
         reg_addr <= 12'h0000;
         wr_data_low_word <= 16'h0000;
      end else begin
         // set dirty flags
         xy_dim_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_XYDIM && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_xy_dim_dirty;
         min_burst_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_MINBURST && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_min_burst_dirty;
         max_burst_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_MAXBURST && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_max_burst_dirty;
         min_delay_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_MINDELAY && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_min_delay_dirty;
         max_delay_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_MAXDELAY && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_max_delay_dirty;
         seed_dirty <= (state == STATE_HIGH_WORD && reg_addr == REG_SEED && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_seed_dirty;
         for(n = 0; n < NUM_LOT_REG; n++)
            lot_dirty[n] <= (state == STATE_HIGH_WORD && reg_addr == (REG_LOT_BASE + n) && dii_flit_in.valid && dii_flit_in.last) ? 1'b1 : nxt_lot_dirty[n];

         // handle incoming dii_flits
         case (state)
            STATE_ADDR: begin
               if (dii_flit_in.valid && !dii_flit_in.last) begin
                  // set next state
                  state <= STATE_LOW_WORD;
                  // store write address
                  reg_addr <= dii_flit_in.data[11:0];
               end
            end
            STATE_LOW_WORD: begin
               if (dii_flit_in.valid) begin
                  // set next state (safeguard in case of sys reset)
                  state <= dii_flit_in.last ? STATE_DRAIN : STATE_HIGH_WORD;
                  // store first data_part
                  wr_data_low_word <= dii_flit_in.data;
               end
            end
            STATE_HIGH_WORD: begin
               if (dii_flit_in.valid) begin
                  // set next state (safeguard in case of sys reset)
                  state <= dii_flit_in.last ? STATE_ADDR : STATE_DRAIN;

                  // write to the registers
                  casez (reg_addr[11:0])
                     REG_MAXCLKCNT: max_clk_counter_reg <= wr_data;
                     REG_XYDIM:     xy_dim <= wr_data;
                     REG_MINBURST:  min_burst <= wr_data;
                     REG_MAXBURST:  max_burst <= wr_data;
                     REG_MINDELAY:  min_delay <= wr_data;
                     REG_MAXDELAY:  max_delay <= wr_data;
                     REG_SEED:      seed <= wr_data;
                     12'h4??: begin
                        if (reg_addr[7:2] < NUM_LOT_REG) begin
                           lot[reg_addr[7:2]] <= {dii_flit_in.data, wr_data_low_word};
                        end
                     end
                     default:;
                  endcase
               end
            end
            STATE_DRAIN: begin
               // ignore all packets until last signal is one
               if (dii_flit_in.valid && dii_flit_in.last) begin
                  state <= STATE_ADDR;
               end
            end
         endcase
      end
   end

   // Set read_addr register
   always_comb begin
      if(xy_dim_dirty)
         read_addr = REG_XYDIM;
      else if(min_burst_dirty)
         read_addr = REG_MINBURST;
      else if(max_burst_dirty)
         read_addr = REG_MAXBURST;
      else if(min_delay_dirty)
         read_addr = REG_MINDELAY;
      else if(max_delay_dirty)
         read_addr = REG_MAXDELAY;
      else if(seed_dirty)
         read_addr = REG_SEED;
      else if(|lot_dirty) begin
         for(m = 0; m < NUM_LOT_REG; m++) begin
            if(lot_dirty[m])
               read_addr = REG_LOT_BASE + (m<<2);
         end
      end
      else
         read_addr = 12'h000;
   end

   // if there is a address to read from (read_addr != 12'h000) set irq
   assign irq = |read_addr;


   /* --------------------------------------------------------------
    * ---------------- Handle request from core --------------------
    * --------------------------------------------------------------*/
   logic wb_enable;
   assign wb_enable = wb_cyc & wb_stb & ~wb_we;

   always_comb begin
      nxt_xy_dim_dirty = xy_dim_dirty;
      nxt_min_burst_dirty = min_burst_dirty;
      nxt_max_burst_dirty = max_burst_dirty;
      nxt_min_delay_dirty = min_delay_dirty;
      nxt_max_delay_dirty = max_delay_dirty;
      nxt_seed_dirty = seed_dirty;
      nxt_lot_dirty = lot_dirty;

      wb_data_out = 32'h0;
      wb_ack = 1'b0;
      wb_err = wb_we; // If write access -> Error, cannot write registers
      if (wb_enable) begin
         casez (wb_addr[11:0])
            REG_ADDR: begin
               wb_data_out = {20'b0, read_addr};
               wb_ack = 1'b1;
               wb_err = 1'b0;
            end

            // Read core configuration
            REG_XYDIM: begin
               wb_data_out = xy_dim;
               wb_ack = 1'b1;
               wb_err = 1'b0;
               nxt_xy_dim_dirty = 1'b0;
            end
            REG_MINBURST: begin
               wb_data_out = min_burst;
               wb_ack = 1'b1;
               wb_err = 1'b0;
               nxt_min_burst_dirty = 1'b0;
            end
            REG_MAXBURST: begin
               wb_data_out = max_burst;
               wb_ack = 1'b1;
               wb_err = 1'b0;
               nxt_max_burst_dirty = 1'b0;
            end
            REG_MINDELAY: begin
               wb_data_out = min_delay;
               wb_ack = 1'b1;
               wb_err = 1'b0;
               nxt_min_delay_dirty = 1'b0;
            end
            REG_MAXDELAY: begin
               wb_data_out = max_delay;
               wb_ack = 1'b1;
               wb_err = 1'b0;
               nxt_max_delay_dirty = 1'b0;
            end
            REG_SEED: begin
                wb_data_out = seed;
                wb_ack = 1'b1;
                wb_err = 1'b0;
                nxt_seed_dirty = 1'b0;
            end
            12'h4??: begin
               if (wb_addr[9:2] > NUM_LOT_REG-1)
                  wb_err = 1'b1;
               else begin
                  wb_data_out = lot[wb_addr[9:2]];
                  wb_ack = 1'b1;
                  wb_err = 1'b0;
                  nxt_lot_dirty[wb_addr[9:2]] = 1'b0;
               end
            end
            default: wb_err = 1'b1; // access to invalid address
         endcase
      end
   end
endmodule // sm_config
