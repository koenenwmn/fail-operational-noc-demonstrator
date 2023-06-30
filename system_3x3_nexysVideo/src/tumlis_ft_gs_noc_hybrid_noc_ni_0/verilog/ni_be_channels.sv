/* Copyright (c) 2019-2020 by the author(s)
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
 * This module holds the individual BE endpoints for all CT Links.
 *
 *
 * Author(s):
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module ni_be_channels #(
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2,
   parameter DEPTH = 16,
   parameter MAX_LEN = 8,
   parameter NUM_BE_ENDPOINTS = 1,
   parameter ENABLE_DR = 0 // Use distributed routing
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   output [CT_LINKS-1:0][FLIT_WIDTH-1:0]  noc_out_flit,
   output [CT_LINKS-1:0]                  noc_out_valid,
   output [CT_LINKS-1:0]                  noc_out_last,
   input [CT_LINKS-1:0]                   noc_out_ready,

   input [CT_LINKS-1:0][FLIT_WIDTH-1:0]   noc_in_flit,
   input [CT_LINKS-1:0]                   noc_in_valid,
   input [CT_LINKS-1:0]                   noc_in_last,
   output [CT_LINKS-1:0]                  noc_in_ready,

   // Bus Side (generic)
   input [31:0]                           bus_addr,
   input                                  bus_we,
   input                                  bus_en,
   input [31:0]                           bus_data_in,
   output [31:0]                          bus_data_out,
   output                                 bus_ack,
   output                                 bus_err,

   output                                 irq
);
   // Ensure that parameters are set to allowed values
   initial begin
      if (FLIT_WIDTH != 32) begin
         $fatal("Currently FLIT_WIDTH must be set to 32.");
      end
      if (CT_LINKS != 2) begin
         $fatal("Currently CT_LINKS must be set to 2.");
      end
      if (NUM_BE_ENDPOINTS > CT_LINKS) begin
         $fatal("NUM_BE_ENDPOINTS must be less or equal than CT_LINKS.");
      end
   end

   wire [CT_LINKS:0]          bus_sel_channel;
   wire [CT_LINKS:0]          bus_err_channel;
   wire [CT_LINKS:0]          bus_ack_channel;
   wire [CT_LINKS:0][31:0]    bus_data_channel;

   wire [CT_LINKS-1:0]        channel_irq;
//------------------------------------------------------------------------------

   // Address bits 19-13 select the channel.
   // The first channel starts at address 0x2000 and each channel has an offset
   // of 0x2000.
   genvar i, j;
   generate
      for (i = 0; i <= CT_LINKS; i++) begin
         assign bus_sel_channel[i] = (bus_addr[19:13] == i);
      end
   endgenerate

   // Multiplex channels to bus
   generate
      for (i = 0; i <= CT_LINKS; i++) begin
         assign bus_data_out = bus_sel_channel[i] ? bus_data_channel[i] : 'z;
      end
   endgenerate
   assign bus_ack = |bus_ack_channel;
   assign bus_err = |bus_err_channel;
   assign irq = |channel_irq;

   assign bus_ack_channel[0] = bus_en & bus_sel_channel[0] & !bus_we & (bus_addr[12:0] == 0);
   assign bus_err_channel[0] = bus_en & bus_sel_channel[0] & (bus_we | (bus_addr[12:0] != 0));
   assign bus_data_channel[0] = {1'(ENABLE_DR), 31'(NUM_BE_ENDPOINTS)};

   // Start Bus Channels for Endpoints at 1 analog to TDM Channels module
   generate
      for (i = 0; i < CT_LINKS; i++) begin : be_endpoints
         if (i < NUM_BE_ENDPOINTS) begin
            ni_be_endpoint #(
               .FLIT_WIDTH(FLIT_WIDTH),
               .DEPTH(DEPTH),
               .MAX_LEN(MAX_LEN),
               .ENABLE_DR(ENABLE_DR))
            u_be_endpoint (
               .clk_bus          (clk_bus),
               .clk_noc          (clk_noc),
               .rst_bus          (rst_bus),
               .rst_noc          (rst_noc),

               .noc_out_flit     (noc_out_flit[i]),
               .noc_out_last     (noc_out_last[i]),
               .noc_out_valid    (noc_out_valid[i]),
               .noc_out_ready    (noc_out_ready[i]),

               .noc_in_flit      (noc_in_flit[i]),
               .noc_in_last      (noc_in_last[i]),
               .noc_in_valid     (noc_in_valid[i]),
               .noc_in_ready     (noc_in_ready[i]),

               .bus_addr         (bus_addr),
               .bus_we           (bus_we),
               .bus_en           (bus_en & bus_sel_channel[i+1]),
               .bus_data_in      (bus_data_in),
               .bus_data_out     (bus_data_channel[i+1]),
               .bus_ack          (bus_ack_channel[i+1]),
               .bus_err          (bus_err_channel[i+1]),
               .irq              (channel_irq[i])
            );
         end else begin
            assign noc_out_flit[i] = '0;
            assign noc_out_last[i] = '0;
            assign noc_out_valid[i] = '0;
            assign noc_in_ready[i] = '0;
            assign bus_data_channel[i+1] = '0;
            assign bus_ack_channel[i+1] = '0;
            assign bus_err_channel[i+1] = '0;
            assign channel_irq[i] = '0;
         end
      end
   endgenerate

endmodule // ni_be_channels
