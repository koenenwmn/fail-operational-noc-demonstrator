/* Copyright (c) 2018-2022 by the author(s)
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
 * This module holds the input and output queues for a single TDM endpoint. Data
 * added to the output queue will be inserted into the NoC according to the slot
 * table of the NI. Data from the NoC that is assigned to this channel will be
 * added to the input queue and an interrupt will be issued. The data must be
 * read before the buffer is full, otherwise arriving traffic will be discarded.
 * The module implements 1+1 protection. The output and input queues are in
 * separate submodules.
 *
 * TODO:
 *    - Status Register
 *    - Write packet: define max. number of flits to be written in one go
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module ni_tdm_endpoint #(
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2,
   parameter LUT_SIZE = 8,
   parameter BUFFER_DEPTH_IN = 16,
   parameter BUFFER_DEPTH_OUT = 16,
   // Max. number of flits between two checkpoints
   parameter MAX_LEN = 8,
   // Width necessary to indicate the maximum length of a bus write/read
   localparam SIZE_WIDTH = $clog2(MAX_LEN+1)
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   input [CT_LINKS-1:0]                   link_enabled,
   // Same signal as above but in tile clock domain
   input [CT_LINKS-1:0]                   link_enabled_tile,

   output [CT_LINKS-1:0][FLIT_WIDTH-1:0]  out_flit,
   output [CT_LINKS-1:0]                  out_valid,
   output [CT_LINKS-1:0]                  out_checkpoint,
   input [CT_LINKS-1:0]                   rd_select,

   input [CT_LINKS-1:0][FLIT_WIDTH-1:0]   in_flit,
   input [CT_LINKS-1:0]                   in_valid,
   input [CT_LINKS-1:0]                   in_checkpoint,
   input [CT_LINKS-1:0]                   in_error,

   // Bus side (generic)
   input [31:0]                           bus_addr,
   input                                  bus_we,
   input                                  bus_en,
   input [31:0]                           bus_data_in,
   output logic [31:0]                    bus_data_out,
   output logic                           bus_ack,
   output                                 bus_err,

   output                                 irq
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (CT_LINKS != 2) begin
         $fatal("ni_tdm_in_queue: CT_LINKS must be set to 2.");
      end
      if (FLIT_WIDTH != 32) begin
         $fatal("Currently FLIT_WIDTH must be set to 32.");
      end
   end

   // Bus addr Selects: Show selected addr and that bus is enabled
   wire                    bus_addr_00_sel;
   wire                    bus_addr_04_sel;
   wire                    bus_addr_08_sel;

   // Addr 0, W: Write to egress queue
   wire                    out_queue_in_valid;
   wire                    out_queue_in_ready;

   // Addr 0, R: Read from ingress queue
   wire [FLIT_WIDTH-1:0]   in_queue_out_flit;
   wire                    in_queue_rd_en;
   wire [SIZE_WIDTH-1:0]   in_queue_size;
   wire                    in_queue_out_valid;
   wire [31:0]             in_queue_out_data;
   reg [SIZE_WIDTH-1:0]    rd_size;

   // Addr 4: Enable endpoint or read status
   reg                     ep_enabled;

   // Bus addr selects: Show selected addr and that bus is enabled
   assign bus_addr_00_sel = (bus_addr[5:2] == 4'h0) & bus_en;
   assign bus_addr_04_sel = (bus_addr[5:2] == 4'h1) & bus_en;
   assign bus_addr_08_sel = (bus_addr[5:2] == 4'h2) & bus_en;

   //---------------------------------------------------------------------------
   /*
    * +------+---+-------------------------------------------------------------+
    * | 0x00 | W | Write to egress queue                                       |
    * +------+---+-------------------------------------------------------------+
    * |      | R | Read from ingress queue                                     |
    * +------+---+-------------------------------------------------------------+
    * | 0x04 | W | Enable endpoint                                             |
    * +------+---+-------------------------------------------------------------+
    * |      | R | Endpoint enabled [0]                                        |
    * +------+---+-------------------------------------------------------------+
    * | 0x08 | W | -                                                           |
    * +------+---+-------------------------------------------------------------+
    * |      | R | Link enabled [1:0]                                          |
    * +------+---+-------------------------------------------------------------+
    */

   // Addr 4: Enable/Disable endpoint
   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         ep_enabled <= 0;
      end else begin
         ep_enabled <= (bus_addr_04_sel & bus_we) ? bus_data_in[0] : ep_enabled;
      end
   end

   // Bus read accesses
   always_comb begin
      bus_data_out = 32'h0;
      bus_ack = 1'b0;
      if(bus_addr_00_sel) begin
         bus_data_out = (~bus_we & in_queue_out_valid & ep_enabled) ? in_queue_out_data : 32'h0;
         bus_ack = bus_we ? out_queue_in_ready : 1'b1;
      end else if (bus_addr_04_sel) begin
         bus_data_out = bus_we ? 32'h0 : {31'h0, ep_enabled};
         bus_ack = 1'b1;
      end else if (bus_addr_08_sel) begin
         bus_data_out = bus_we ? 32'h0 : {{FLIT_WIDTH-CT_LINKS{1'b0}}, link_enabled_tile};
         bus_ack = 1'b1;
      end
   end
   // Issue a bus error, if the bus is enabled but the address doesn't match
   assign bus_err = bus_en & ~(bus_addr_00_sel | bus_addr_04_sel | bus_addr_08_sel);
   // Issue an interrupt, whenever flits are available in the in queue
   // and the endpoint has been enabled. If the endpoint is not enabled the
   // flits will be discarded.
   assign irq = in_queue_out_valid & ep_enabled;

   assign out_queue_in_valid = bus_addr_00_sel & bus_we;
   ni_tdm_out_queue #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .CT_LINKS(CT_LINKS),
      .LUT_SIZE(LUT_SIZE),
      .DEPTH(BUFFER_DEPTH_OUT),
      .MAX_LEN(MAX_LEN))
   u_out_queue (
      .clk_bus             (clk_bus),
      .clk_noc             (clk_noc),
      .rst_bus             (rst_bus),
      .rst_noc             (rst_noc),
      .link_enabled        (link_enabled),
      .in_data             (bus_data_in),
      .in_valid            (out_queue_in_valid),
      .in_ready            (out_queue_in_ready),
      .out_flit            (out_flit),
      .out_valid           (out_valid),
      .out_checkpoint      (out_checkpoint),
      .select              (rd_select)
   );

   // 0x0,R: Read from ingress queue
   // First, reads number of flits currently in the in queue into rd_size reg
   // and puts onto bus.
   // Afterwards, read 'rd_size' number of flits from in queue and put on bus.
   always_ff @ (posedge clk_bus) begin
      if(rst_bus) begin
         rd_size <= 0;
      end else begin
         if(in_queue_out_valid & ((bus_addr_00_sel & ~bus_we) | ~ep_enabled)) begin
            rd_size <= (rd_size == 0) ? (in_queue_size > MAX_LEN ? MAX_LEN : in_queue_size) : (rd_size - 1);
         end else begin
            rd_size <= rd_size;
         end
      end
   end
   assign in_queue_rd_en = ((rd_size != 0) & ((bus_addr_00_sel & ~bus_we) | ~ep_enabled));
   assign in_queue_out_data = in_queue_rd_en ? in_queue_out_flit : (in_queue_size > MAX_LEN ? {{32-SIZE_WIDTH{1'h0}}, MAX_LEN} : {{32-SIZE_WIDTH{1'h0}}, in_queue_size});

   ni_tdm_in_queue #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .CT_LINKS(CT_LINKS),
      .DEPTH(BUFFER_DEPTH_IN),
      .MAX_LEN(MAX_LEN),
      .LUT_SIZE(LUT_SIZE))
   u_in_queue (
      .clk_bus                   (clk_bus),
      .clk_noc                   (clk_noc),
      .rst_bus                   (rst_bus),
      .rst_noc                   (rst_noc),
      .out_flit                  (in_queue_out_flit),
      .out_valid                 (in_queue_out_valid),
      .out_ready                 (in_queue_rd_en),
      .num_flits_in_queue        (in_queue_size),
      .in_flit                   (in_flit),
      .in_valid                  (in_valid),
      .in_checkpoint             (in_checkpoint),
      .in_error                  (in_error)
   );

endmodule // ni_tdm_endpoint
