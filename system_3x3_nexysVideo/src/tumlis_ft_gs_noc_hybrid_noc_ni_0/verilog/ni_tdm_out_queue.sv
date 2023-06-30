/* Copyright (c) 2019-2022 by the author(s)
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
 * This is the out queue of a TDM endpoint. The data to be sent is written to a
 * CDC FIFO to cross form the bus to the NoC domain. The data is then written to
 * a dual read port FIFO from where the flits are sent via both links.
 * The module takes care of inserting checkpoints into the data stream (number
 * flits that have been sent) which is used for path synchronization in the
 * receiving NI.
 * The dual read port FIFO is blocking in case a flit has not been read from
 * both read ports. If only one link is used the other one must be disabled in
 * order to drain flits from the corresponding read port.
 *
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module ni_tdm_out_queue #(
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2, // Currently only 2 links are supported
   parameter LUT_SIZE = 8,
   parameter DEPTH = 16,
   // Max. number of flits between two checkpoints
   parameter MAX_LEN = 8,
   // The output buffer size must be a power of two and have at least the size
   // LUT_SIZE/2, which is the max. difference in sent flits the two channels
   // can have.
   localparam OUT_BUFF_DEPTH = (1 << $clog2(LUT_SIZE >= 4 ? LUT_SIZE/2 : 2)),
   localparam DIST_CNT_WIDTH = $clog2(MAX_LEN),
   // Width of the counters
   localparam CNT_WIDTH = 16
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   input [CT_LINKS-1:0]                   link_enabled,

   input [FLIT_WIDTH-1:0]                 in_data,
   input                                  in_valid,
   output                                 in_ready,

   output [CT_LINKS-1:0][FLIT_WIDTH-1:0]  out_flit,
   output [CT_LINKS-1:0]                  out_valid,
   output [CT_LINKS-1:0]                  out_checkpoint,
   input [CT_LINKS-1:0]                   select
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (CT_LINKS != 2) begin
         $fatal("ni_tdm_out_queue: CT_LINKS must be set to 2.");
      end
   end

   wire [FLIT_WIDTH-1:0]         cdc_out_flit;
   wire                          cdc_rd_en;
   wire                          cdc_full;
   wire                          cdc_empty;

   // Before every packet, a checkpoint should be inserted
   reg [CNT_WIDTH-1:0]           checkpoint;
   reg                           write_checkpoint;
   reg [DIST_CNT_WIDTH-1:0]      dist_cnt;

   wire [FLIT_WIDTH-1:0]         out_buffer_in_flit;
   wire                          out_buffer_in_cp;
   wire                          out_buffer_wr_en;
   wire                          out_buffer_full;
   wire [1:0]                    out_buffer_out_last;
   wire [1:0]                    out_buffer_rd_en;
   wire [1:0]                    out_buffer_empty;

   // Signals to drain deactivated links
   reg [CT_LINKS-1:0]            reg_link_enabled;
   wire [CT_LINKS-1:0]           set_link_enabled;

   //---------------------------------------------------------------------------

   // The CDC FIFO is used to cross from the Bus to the NoC clock domain.
   fifo_dualclock_fwft #(
      .WIDTH(FLIT_WIDTH),
      .DEPTH(DEPTH))
   u_out_cdc(
      .wr_clk     (clk_bus),
      .wr_rst     (rst_bus),
      .wr_en      (in_valid),
      .din        (in_data),

      .rd_clk     (clk_noc),
      .rd_rst     (rst_noc),
      .rd_en      (cdc_rd_en),
      .dout       (cdc_out_flit),

      .full       (cdc_full),
      .prog_full  (),
      .empty      (cdc_empty),
      .prog_empty ()
   );
   assign in_ready = ~cdc_full;

   // Checkpoint logic
   // Before every NoC packet, a checkpoint is inserted, so the packet can be
   // identified in the in queue of the receiving endpoint.
   always_ff @(posedge clk_noc) begin
      if (rst_noc) begin
         checkpoint <= 0;
         dist_cnt <= 0;
         write_checkpoint <= 1;
      end else begin
         // Take care of inserting checkpoints
         if (out_buffer_wr_en & ~out_buffer_full) begin
            if (write_checkpoint) begin
               write_checkpoint <= 0;
            end else begin
               checkpoint <= checkpoint + 1'b1;
               if (dist_cnt >= MAX_LEN - 1) begin
                  dist_cnt <= 'b0;
                  write_checkpoint <= 1;
               end else begin
                  dist_cnt <= dist_cnt + 1'b1;
               end
            end
         end
      end
   end


   // Read from CDC Fifo when out_buffer is not full and no checkpoint is inserted
   assign cdc_rd_en = ~out_buffer_full & ~write_checkpoint & out_buffer_wr_en;
   assign out_buffer_wr_en = ~cdc_empty;
   // Mux to Out Buffer: Decide whether to insert a checkpoint or data from queue
   assign out_buffer_in_flit = write_checkpoint ? {{(FLIT_WIDTH - CNT_WIDTH){1'b0}}, checkpoint} : cdc_out_flit;
   assign out_buffer_in_cp = write_checkpoint;


   // Dual Buffer for flits to be sent on the CT Links into the NoC.
   // This includes checkpoint numbers, parity bits, and last flags.
   fifo_singleclock_dual_rd_port_fwft #(
      .WIDTH(FLIT_WIDTH + 1),
      .DEPTH(OUT_BUFF_DEPTH))
   u_out_buffer (
      .clk        (clk_noc),
      .rst        (rst_noc),
      .din        ({out_buffer_in_cp, out_buffer_in_flit}),
      .wr_en      (out_buffer_wr_en),
      .full       (out_buffer_full),
      .prog_full  (),
      .dout       ({out_checkpoint[1], out_flit[1], out_checkpoint[0], out_flit[0]}),
      .rd_en      (out_buffer_rd_en),
      .empty      (out_buffer_empty)
   );

   genvar l;
   generate
      for (l = 0; l < CT_LINKS; l++) begin
         // Only enable a link when the out buffer is empty or a checkpoint is
         // waiting to be sent. Disabling happens right away.
         always_ff @(posedge clk_noc) begin
            if (rst_noc) begin
               reg_link_enabled[l] <= 0;
            end else begin
               reg_link_enabled[l] <= link_enabled[l] ? (set_link_enabled[l] ? 1'b1 : reg_link_enabled[l]) : 1'b0;
            end
         end

         // Generate output wiring. Drain disabled links.
         assign out_buffer_rd_en[l] = ~link_enabled[l] | (select[l] & reg_link_enabled[l]);
         assign out_valid[l] = ~out_buffer_empty[l] & reg_link_enabled[l] & link_enabled[l];
         assign set_link_enabled[l] = (out_checkpoint[l] | out_buffer_empty[l]) & link_enabled[l] & ~reg_link_enabled[l];
      end
   endgenerate

endmodule // ni_tdm_out_queue
