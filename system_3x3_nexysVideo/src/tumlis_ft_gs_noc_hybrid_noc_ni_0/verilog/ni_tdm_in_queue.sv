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
 * This is the in queue of a TDM endpoint. The module keeps track of the
 * checkpoints and the amount of flits received on both links. Duplicates are
 * ignored. If a checkpoint arrives that is way ahead of the current checkpoint
 * it is assumed that flits have been missed and the current checkpoint is
 * updated to the new one.
 * Received flits are written to a CDC FIFO tro cross from the NoC to the bus
 * domain. From there they are written to a small buffer. A counter keeps track
 * of the amount of flits in this small buffer which is necessary for the read
 * operation via the bus.
 * If flits arrive while the CDC FIFO is full they will be dropped.
 * There are currently no status registers that keep track of the number of
 * faulty flits or buffer overruns.
 *
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module ni_tdm_in_queue #(
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2, // Currently only 2 links are supported
   parameter DEPTH = 16,
   // Max. number of flits between two checkpoints
   parameter MAX_LEN = 8,
   parameter LUT_SIZE = 8,
   // Width necessary to show the fill count of a full NoC Buffer
   localparam SIZE_WIDTH = $clog2(MAX_LEN+1),
   // Width of the counters
   localparam CNT_WIDTH = 16,
   // Define when a flit counter is considered 'way behind'.
   // With equidistant paths the distance of the flit counters should never be
   // >= LUT_SIZE, however, with different path lengths the distance may well be
   // larger. Set to 4 * LUT_SIZE to have some margin.
   localparam BEHIND_THR = (2 ** CNT_WIDTH) - (LUT_SIZE * 4),
   // Same as above just for being ahead.
   localparam AHEAD_THR = LUT_SIZE * 4
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   output [FLIT_WIDTH-1:0]                out_flit,
   output                                 out_valid,
   input                                  out_ready,
   output [SIZE_WIDTH-1:0]                num_flits_in_queue,

   input [CT_LINKS-1:0][FLIT_WIDTH-1:0]   in_flit,
   input [CT_LINKS-1:0]                   in_valid,
   input [CT_LINKS-1:0]                   in_checkpoint,
   input [CT_LINKS-1:0]                   in_error
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (CT_LINKS != 2) begin
         $fatal("ni_tdm_in_queue: CT_LINKS must be set to 2.");
      end
   end


   /*
    * Signals & registers
    */

   // CDC FIFO signals
   wire [FLIT_WIDTH-1:0]                  cdc_in_flit;
   wire                                   cdc_wr_en;
   wire                                   cdc_full;
   wire [FLIT_WIDTH-1:0]                  cdc_out_flit;
   wire                                   cdc_rd_en;
   wire                                   cdc_empty;

   // Output Queue
   wire [FLIT_WIDTH-1:0]                  queue_in_flit;
   wire                                   queue_wr_en;
   wire                                   queue_full;
   wire [FLIT_WIDTH-1:0]                  queue_out_flit;
   wire                                   queue_rd_en;
   wire                                   queue_empty;

   // Status registers and signals, NoC side
   reg [CT_LINKS-1:0][CNT_WIDTH-1:0]      in_flit_cnt;
   reg [CNT_WIDTH-1:0]                    cdc_flit_cnt;
   wire                                   link_select;

   // Status registers and signals, bus side
   reg [SIZE_WIDTH-1:0]                   status_queue_fill;
   wire                                   write_to_queue;
   wire                                   read_from_queue;

   // Distance of the in flit counters and the CDC flit counter.
   // The distance is calculated by subtraction with the two's complement.
   wire [CT_LINKS-1:0][CNT_WIDTH-1:0]     checkpoint_dist;
   wire [CNT_WIDTH-1:0]                   cdc_in_cnt_twos_compl;
   wire [CT_LINKS-1:0]                    checkpoint_way_ahead;
   wire [CT_LINKS-1:0]                    update_checkpoint;

   // The link data is 'ok' if the flit is a valid data flit (no checkpoint),
   // there is no error in the flit, and the flit counter of the link matches
   // the CDC flit counter.
   wire [CT_LINKS-1:0]                    link_data_ok;


   /*
    * Wiring & logic
    */

   assign cdc_in_cnt_twos_compl = ~cdc_flit_cnt + 1'b1;
   genvar i;
   generate
      for(i = 0; i < CT_LINKS; i++) begin
         // Determine distance between current CDC FIFO flit counter and new
         // incoming checkpoint. If the new checkpoint is more than AHEAD_THR
         // flits ahead but less than BEHIND_THR -> update CDC FIFO flit counter
         assign checkpoint_dist[i] = in_flit[i][CNT_WIDTH-1:0] + cdc_in_cnt_twos_compl;
         assign checkpoint_way_ahead[i] = (checkpoint_dist[i] >= AHEAD_THR && checkpoint_dist[i] <= BEHIND_THR) ? 1 : 0;
         assign update_checkpoint[i] = checkpoint_way_ahead[i] & in_valid[i] & in_checkpoint[i] & ~in_error[i];

         // Check if data on links is 'ok'
         assign link_data_ok[i] = in_valid[i] & ~in_checkpoint[i] & ~in_error[i] & (in_flit_cnt[i] == cdc_flit_cnt);

         // Handle link status registers
         always_ff @(posedge clk_noc) begin
            if(rst_noc) begin
               in_flit_cnt[i] <= 0;
            end else begin
               // Update checkpoint if received, otherwise increase counter if
               // valid flit received, otherwise unchanged
               in_flit_cnt[i] <= in_valid[i] ? (in_checkpoint[i] ? in_flit[i][CNT_WIDTH-1:0] : in_flit_cnt[i] + 1'b1) : in_flit_cnt[i];
            end
         end
      end
   endgenerate

   // Handle NoC side status registers
   always_ff @(posedge clk_noc) begin
      if(rst_noc) begin
         cdc_flit_cnt <= 0;
      end else begin
         if(update_checkpoint[0]) begin
            cdc_flit_cnt <= in_flit[0][CNT_WIDTH-1:0];
         end else if(update_checkpoint[1]) begin
            cdc_flit_cnt <= in_flit[1][CNT_WIDTH-1:0];
         end else begin
            cdc_flit_cnt <= cdc_flit_cnt + cdc_wr_en;
         end
      end
   end

   // Update status register with queue fill level
   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         status_queue_fill <= 0;
      end else begin
         if(write_to_queue & ~read_from_queue) begin
            status_queue_fill <= status_queue_fill + 1'b1;
         end else if(~write_to_queue & read_from_queue) begin
            status_queue_fill <= status_queue_fill - 1'b1;
         end else begin
            status_queue_fill <= status_queue_fill;
         end
      end
   end
   assign write_to_queue = queue_wr_en & ~queue_full;
   assign read_from_queue = queue_rd_en & ~queue_empty;
   assign num_flits_in_queue = status_queue_fill;


   /*
    * Buffer queues
    */

   // Connect links to CDC FIFO
   assign link_select = link_data_ok[1] ? 1 : 0;
   assign cdc_in_flit = in_flit[link_select];
   assign cdc_wr_en = |link_data_ok;

   // The CDC FIFO is used to cross from the NoC to the bus clock domain.
   fifo_dualclock_fwft #(
      .WIDTH(FLIT_WIDTH),
      .DEPTH(DEPTH))
   u_in_cdc(
      .wr_clk     (clk_noc),
      .wr_rst     (rst_noc),
      .wr_en      (cdc_wr_en),
      .din        (cdc_in_flit),

      .rd_clk     (clk_bus),
      .rd_rst     (rst_bus),
      .rd_en      (cdc_rd_en),
      .dout       (cdc_out_flit),

      .full       (cdc_full),
      .prog_full  (),
      .empty      (cdc_empty),
      .prog_empty ()
   );
   assign cdc_rd_en = ~queue_full;
   assign queue_in_flit = cdc_out_flit;
   assign queue_wr_en = ~cdc_empty;

   // The in queue holds the flits that are ready to be read via the bus.
   // A counter keeps track if the number of flits in the queue which is needed
   // by the core in order to read the correct number of flits (or at least not
   // more flits than are queued).
   fifo_singleclock_fwft #(
      .DEPTH(1 << $clog2(MAX_LEN)),
      .WIDTH(FLIT_WIDTH))
   u_in_queue(
      .clk           (clk_bus),
      .rst           (rst_bus),
      .din           (queue_in_flit),
      .wr_en         (queue_wr_en),
      .full          (queue_full),
      .prog_full     (),
      .dout          (queue_out_flit),
      .rd_en         (queue_rd_en),
      .empty         (queue_empty)
   );
   assign out_flit = queue_out_flit;
   assign queue_rd_en = out_ready;
   assign out_valid = ~queue_empty;

endmodule // ni_tdm_in_queue
