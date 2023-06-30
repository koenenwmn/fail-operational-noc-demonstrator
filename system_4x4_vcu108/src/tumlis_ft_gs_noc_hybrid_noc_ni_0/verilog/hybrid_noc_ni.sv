/* Copyright (c) 2018-2020 by the author(s)
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
 * This is the network interface for compute tiles. It is configurable to
 * contain different elements (e.g. message passing or DMA) and supports a
 * configurable number of TDM connections. Its BE part is compatible with the
 * OpTiMSoC network adapter.
 *
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

import optimsoc_config::*;

module hybrid_noc_ni #(
   // Only parameter that must be defined right now is NUMCTS.
   // It is used to generate the ct_list vector in the ni_config module.
   parameter config_t CONFIG = {32'h9,32'h9,'x},
   parameter TILEID = 'x,
   parameter COREBASE = 'x,

   parameter ADDR_WIDTH = 24,
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2,
   parameter LUT_SIZE = 16,
   parameter TDM_CHANNELS = 4,
   parameter TDM_BUFFER_DEPTH_IN = 16,
   parameter TDM_BUFFER_DEPTH_OUT = 16,
   parameter TDM_MAX_CHECKPOINT_DIST = 8,
   parameter BE_BUFFER_DEPTH = 16,
   parameter MAX_BE_PKT_LEN = 8,
   parameter NUM_BE_ENDPOINTS = 1,
   parameter ENABLE_FDM = 1,
   parameter FAULTS_PERMANENT = 0,

   parameter ENABLE_DR = 0,   // Use distributed routing

   localparam PARITY_BITS = ENABLE_FDM ? FLIT_WIDTH / 8 : 0,
   localparam LINK_WIDTH = FLIT_WIDTH + PARITY_BITS,
   localparam SLAVES = 3,
   // The slave IDs for the corresponding submodules.
   localparam ID_CONF = 0,
   localparam ID_BE = 1,
   localparam ID_TDM = 2
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   input [CT_LINKS-1:0][LINK_WIDTH-1:0]   in_flit,
   input [CT_LINKS-1:0]                   in_last,
   input [CT_LINKS-1:0]                   tdm_in_valid,
   input [CT_LINKS-1:0]                   be_in_valid,
   output [CT_LINKS-1:0]                  be_in_ready,
   output [CT_LINKS-1:0]                  link_error,

   output [CT_LINKS-1:0][LINK_WIDTH-1:0]  out_flit,
   output [CT_LINKS-1:0]                  out_last,
   output [CT_LINKS-1:0]                  tdm_out_valid,
   output [CT_LINKS-1:0]                  be_out_valid,
   input [CT_LINKS-1:0]                   be_out_ready,

   input [31:0]                           wb_addr,
   input                                  wb_cyc,
   input [31:0]                           wb_data_in,
   input [3:0]                            wb_sel,     // unused
   input                                  wb_stb,
   input                                  wb_we,
   input                                  wb_cab,     // unused
   input [2:0]                            wb_cti,     // unused
   input [1:0]                            wb_bte,     // unused
   output                                 wb_ack,
   output                                 wb_rty,     // unused
   output                                 wb_err,
   output [31:0]                          wb_data_out,

   output [3:0]                           irq,        // from LSB to MSB: BE received, BE DMA, TDM received, TDM DMA

   // Interface for writing to slot tables.
   input [$clog2(TDM_CHANNELS+1)-1:0]     lut_conf_data,
   input [$clog2(TDM_CHANNELS)-1:0]       lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]           lut_conf_slot,
   input                                  lut_conf_valid,
   // Same interface is used to enable links for outgoing channels
   input                                  link_en_valid
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (BE_BUFFER_DEPTH < MAX_BE_PKT_LEN) begin
         $fatal("BUFFER_DEPTH must be >= PACKET_MAX_LEN.");
      end
      if (CT_LINKS != 2) begin
         $fatal("Currently CT_LINKS must be set to 2.");
      end
      if (FLIT_WIDTH != 32) begin
         $fatal("Currently FLIT_WIDTH must be set to 32.");
      end
   end

   // Bus Wiring
   wire [31:0]                            bus_addr;
   wire                                   bus_we;
   wire [SLAVES-1:0]                      bus_en;
   wire [31:0]                            bus_data_in;
   wire [SLAVES-1:0][31:0]                bus_data_out;
   wire [SLAVES-1:0]                      bus_ack;
   wire [SLAVES-1:0]                      bus_err;

   // Noc I/O Wiring
   wire [CT_LINKS-1:0][LINK_WIDTH-1:0]    tdm_out_flit;
   wire [CT_LINKS-1:0]                    tdm_out_last;
   wire [CT_LINKS-1:0]                    be_out_enable;
   wire [CT_LINKS-1:0][FLIT_WIDTH-1:0]    be_out_flit;
   wire [CT_LINKS-1:0][FLIT_WIDTH-1:0]    be_in_flit;
   wire [CT_LINKS-1:0]                    be_out_last;
   wire [CT_LINKS-1:0]                    channel_be_out_valid;

   // DMAs are currently not provided. IRQ lines are wired to '0'
   assign irq[1] = 1'b0;
   assign irq[3] = 1'b0;

//------------------------------------------------------------------------------

   // Address Bits 23-20 define the Slave ID to address the different modules
   // Slave 0: Configuration           (Addr = 0x0*****)
   // Slave 1: BE Channels             (Addr = 0x1*****)
   // Slave 2: TDM Channels            (Addr = 0x2*****)

   // Wishbone Bus (B3) Slave Decoder
   // The Slave Decoder chooses, depending on the address bits 23-20,
   // which bus slave will be enabled. It also combines some wishbone signals,
   // so that the slave modules can be addressed using a generic Bus Interface.
   ni_slave_decode #(
      .SLAVES(SLAVES),
      .SLAVE_ID_WIDTH(4),
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(32))
   u_slave_decode(
      .clk              (clk_bus),
      .rst              (rst_bus),

      .wb_addr          (wb_addr[ADDR_WIDTH-1:0]),
      .wb_data_in       (wb_data_in),
      .wb_cyc           (wb_cyc),
      .wb_stb           (wb_stb),
      .wb_sel           (wb_sel),      // unused
      .wb_we            (wb_we),
      .wb_cti           (wb_cti),      // unused
      .wb_bte           (wb_bte),      // unused
      .wb_data_out      (wb_data_out),
      .wb_ack           (wb_ack),
      .wb_err           (wb_err),
      .wb_rty           (wb_rty),      // unused

      .bus_addr         (bus_addr[ADDR_WIDTH-1:0]),
      .bus_we           (bus_we),
      .bus_en           (bus_en),
      .bus_data_in      (bus_data_in),
      .bus_data_out     (bus_data_out),
      .bus_ack          (bus_ack),
      .bus_err          (bus_err)
   );
   assign bus_addr[31:ADDR_WIDTH] = 0;


   // Network Interface Config
   // Similar to the OptimSoC Config Module, the Network Interface Config
   // holds information about the compute tile and the NoC.
   // This information can be read from memory mapped registers via the bus.
   ni_config #(
      .CONFIG(CONFIG),
      .TILEID(TILEID),
      .COREBASE(COREBASE))
   u_config(
      .clk              (clk_bus),
      .rst              (rst_bus),

      .bus_addr         (bus_addr),
      .bus_we           (bus_we),
      .bus_en           (bus_en[ID_CONF]),
      .bus_data_in      (bus_data_in),
      .bus_data_out     (bus_data_out[ID_CONF]),
      .bus_ack          (bus_ack[ID_CONF]),
      .bus_err          (bus_err[ID_CONF])
   );

   // TDM Channels Module
   // The Channels Module holds all the TDM Endpoints of the Network Interface.
   // Each Endpoint interfaces both CT Links and is used for one TDM Channel
   // in the NoC.
   // Address Channel i using addr[19:13] = (i+1)
   ni_tdm_channels #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .CT_LINKS(CT_LINKS),
      .CHANNELS(TDM_CHANNELS),
      .LUT_SIZE(LUT_SIZE),
      .BUFFER_DEPTH_IN(TDM_BUFFER_DEPTH_IN),
      .BUFFER_DEPTH_OUT(TDM_BUFFER_DEPTH_OUT),
      .MAX_LEN(TDM_MAX_CHECKPOINT_DIST),
      .ENABLE_FDM(ENABLE_FDM),
      .FAULTS_PERMANENT(FAULTS_PERMANENT))
   u_tdm_channels (
      .clk_bus             (clk_bus),
      .clk_noc             (clk_noc),
      .rst_bus             (rst_bus),
      .rst_noc             (rst_noc),

      .noc_out_flit        (tdm_out_flit),
      .noc_out_valid       (tdm_out_valid),
      .noc_out_last        (tdm_out_last),
      .noc_in_flit         (in_flit),
      .noc_in_valid        (tdm_in_valid),
      .noc_in_last         (in_last),
      .be_out_enable       (be_out_enable),
      .link_error          (link_error),

      .bus_addr            (bus_addr),
      .bus_we              (bus_we),
      .bus_en              (bus_en[ID_TDM]),
      .bus_data_in         (bus_data_in),
      .bus_data_out        (bus_data_out[ID_TDM]),
      .bus_ack             (bus_ack[ID_TDM]),
      .bus_err             (bus_err[ID_TDM]),
      .irq                 (irq[2]),

      .lut_conf_data       (lut_conf_data),
      .lut_conf_sel        (lut_conf_sel),
      .lut_conf_slot       (lut_conf_slot),
      .lut_conf_valid      (lut_conf_valid),
      .link_en_valid       (link_en_valid)
   );


   // Only use the data flits without parity for the BE Endpoints
   genvar i;
   generate
      for (i = 0; i < CT_LINKS; i++) begin
         assign be_in_flit[i] = in_flit[i][FLIT_WIDTH-1:0];
      end
   endgenerate

   // Best Effort (BE) Channels
   // The Module holds all BE Endpoint, one for each CT Link.
   // Address Channel i using addr[19:13] = (i+1)
   // Use addr[5:0] = 0 to access NoC w/r.
   ni_be_channels #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .CT_LINKS(CT_LINKS),
      .DEPTH(BE_BUFFER_DEPTH),
      .MAX_LEN(MAX_BE_PKT_LEN),
      .NUM_BE_ENDPOINTS(NUM_BE_ENDPOINTS),
      .ENABLE_DR(ENABLE_DR))
   u_be_channels (
      .clk_bus             (clk_bus),
      .clk_noc             (clk_noc),
      .rst_bus             (rst_bus),
      .rst_noc             (rst_noc),

      .noc_out_flit        (be_out_flit),
      .noc_out_valid       (channel_be_out_valid),
      .noc_out_last        (be_out_last),
      .noc_out_ready       (be_out_ready & be_out_enable),

      .noc_in_flit         (be_in_flit),
      .noc_in_valid        (be_in_valid),
      .noc_in_last         (in_last),
      .noc_in_ready        (be_in_ready),

      .bus_addr            (bus_addr),
      .bus_we              (bus_we),
      .bus_en              (bus_en[ID_BE]),
      .bus_data_in         (bus_data_in),
      .bus_data_out        (bus_data_out[ID_BE]),
      .bus_ack             (bus_ack[ID_BE]),
      .bus_err             (bus_err[ID_BE]),
      .irq                 (irq[0])
   );

   // NoC output MUX
   // Whenever there is no data available for the current TDM slot,
   // packets from the BE Endpoints can be written to the NoC.
   generate
      for (i = 0; i < CT_LINKS; i++) begin
         assign out_flit[i] = be_out_enable[i] ? {{PARITY_BITS{1'b0}}, be_out_flit[i]} : tdm_out_flit[i];
         assign out_last[i] = be_out_enable[i] ? be_out_last[i] : tdm_out_last[i];
         // BE should only be valid, if no TDM data is currently transmitted
         assign be_out_valid[i] = channel_be_out_valid[i] & be_out_enable[i];
      end
   endgenerate

endmodule // hybrid_noc_ni
