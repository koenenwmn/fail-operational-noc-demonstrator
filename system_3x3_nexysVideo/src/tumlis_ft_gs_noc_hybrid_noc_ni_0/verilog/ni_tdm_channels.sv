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
 * This module holds the individual TDM endpoints as well as the Input and
 * Output TDM slot tables.
 * Furthermore, the module contains submodules which take care of calculating
 * the parity bits before sending a flit into the NoC and of a last parity check
 * before forwarding a received flit to the corresponding channel.
 *
 * TODO:
 *       - link_error: output from in_queue -> endpoint -> channels, not from FDM?
 *       - bus data out: =0 oder =z, wenn bus_addr_wrong?
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module ni_tdm_channels #(
   parameter FLIT_WIDTH = 32,
   parameter CT_LINKS = 2,
   parameter CHANNELS = 4,
   parameter LUT_SIZE = 8,
   parameter BUFFER_DEPTH_IN = 16,
   parameter BUFFER_DEPTH_OUT = 16,
   parameter MAX_LEN = 8, // Max. number of flits between two checkpoints
   parameter ENABLE_FDM = 1,
   parameter FAULTS_PERMANENT = 0,
   localparam PARITY_BITS = ENABLE_FDM ? FLIT_WIDTH / 8 : 0,
   localparam LINK_WIDTH = ENABLE_FDM ? FLIT_WIDTH + PARITY_BITS : FLIT_WIDTH,
   localparam LUT_PORTS = CHANNELS < CT_LINKS * 2 ? CT_LINKS * 2 : CHANNELS
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   output [CT_LINKS-1:0][LINK_WIDTH-1:0]  noc_out_flit,
   output [CT_LINKS-1:0]                  noc_out_valid,
   output [CT_LINKS-1:0]                  noc_out_last,

   input [CT_LINKS-1:0][LINK_WIDTH-1:0]   noc_in_flit,
   input [CT_LINKS-1:0]                   noc_in_valid,
   input [CT_LINKS-1:0]                   noc_in_last,

   output [CT_LINKS-1:0]                  be_out_enable,
   output [CT_LINKS-1:0]                  link_error,

   // Bus side (generic)
   input [31:0]                           bus_addr,
   input                                  bus_we,
   input                                  bus_en,
   input [31:0]                           bus_data_in,
   output [31:0]                          bus_data_out,
   output                                 bus_ack,
   output                                 bus_err,

   output                                 irq,

   // Interface for writing to slot tables.
   input [$clog2(CHANNELS+1)-1:0]         lut_conf_data,
   input [$clog2(CHANNELS)-1:0]           lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]           lut_conf_slot,
   input                                  lut_conf_valid,
   // Same interface is used to enable links for outgoing channels
   input                                  link_en_valid
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (CHANNELS > 16) begin
         $fatal("ni_tdm_channels: CHANNELS must be <= 16.");
      end else if (LUT_SIZE > 256) begin
         $fatal("ni_tdm_channels: LUT_SIZE must be <= 256.");
      end
      // PARITY_BITS must currently be set to FLIT_WIDTH / 8 or to o
      if (PARITY_BITS != 0 && PARITY_BITS != FLIT_WIDTH / 8) begin
         $fatal("ni_tdm_channels: PARITY_BITS must either be FLIT_WIDTH / 8, or 0.");
      end
   end

   // Separate Incoming Flits into data flit and parity
   wire [CT_LINKS-1:0][FLIT_WIDTH-1:0]                   noc_in_flit_only;
   wire [CT_LINKS-1:0][PARITY_BITS-1:0]                  noc_in_parity;

   // Select signals from the slot tables
   wire [CT_LINKS-1:0][$clog2(CHANNELS+1)-1:0]           rd_select;
   wire [CT_LINKS-1:0]                                   rd_select_valid;
   wire [CT_LINKS-1:0][$clog2(CHANNELS+1)-1:0]           wr_select;
   wire [CHANNELS-1:0][CT_LINKS-1:0]                     channel_rd_select; // read from endpoint (inject into NoC)
   wire [CHANNELS-1:0][CT_LINKS-1:0]                     channel_wr_select; // write to endpoint (receive from NoC)

   // EP link enable signals
   reg [CHANNELS-1:0][CT_LINKS-1:0]                      link_enabled;
   (* ASYNC_REG = "true" *) reg [CHANNELS-1:0][CT_LINKS-1:0] link_enabled_cdc_0, link_enabled_cdc_1;
   wire [CHANNELS-1:0][CT_LINKS-1:0]                     link_enabled_tile;

   wire [CHANNELS-1:0][CT_LINKS-1:0][FLIT_WIDTH-1:0]     channel_out_flit;
   wire [CHANNELS-1:0][CT_LINKS-1:0]                     channel_out_valid;
   wire [CHANNELS-1:0][CT_LINKS-1:0]                     channel_out_checkpoint;
   wire [CHANNELS-1:0]                                   channel_irq;
   wire [CT_LINKS-1:0][FLIT_WIDTH-1:0]                   out_flit; // out flit w/o parity bits

   wire [CHANNELS:0]                                     bus_sel_channel;
   wire [CHANNELS:0]                                     bus_err_channel;
   wire [CHANNELS:0]                                     bus_ack_channel;
   wire [CHANNELS:0][31:0]                               bus_data_channel;
   wire                                                  bus_addr_wrong;
   //------------------------------------------------------------------------------

   // Address bits 19-13 select the channel.
   // The first channel starts at address 0x2000 and each channel has an offset
   // of 0x2000.
   genvar i, j;
   generate
      for (i = 0; i <= CHANNELS; i++) begin
         assign bus_sel_channel[i] = (bus_addr[19:13] == i);
      end
   endgenerate
   assign bus_addr_wrong = bus_en & ~(|bus_sel_channel);

   // Multiplex channels to bus
   generate
      for(i = 0; i <= CHANNELS; i++) begin
         assign bus_data_out = bus_sel_channel[i] ? bus_data_channel[i] : 'z;
      end
   endgenerate

   assign irq = |channel_irq;
   assign bus_ack = |bus_ack_channel;
   assign bus_err = |bus_err_channel | bus_addr_wrong;

   // Reading from address 0x0000 returns the number of available
   // channels/endpoints, the current ingress link status, and the max. number
   // of words that can be written to an endpoint in one go.
   assign bus_ack_channel[0] = bus_en & bus_sel_channel[0] & !bus_we & (bus_addr[12:0] == 0);
   assign bus_err_channel[0] = bus_en & bus_sel_channel[0] & (bus_we | (bus_addr[12:0] != 0));
   assign bus_data_channel[0] = CHANNELS | MAX_LEN << 16;

   // Store enabled channels
   always_ff @(posedge clk_noc) begin
      if (rst_noc) begin
         link_enabled <= 0;
      end else begin
         if (link_en_valid) begin
            link_enabled[lut_conf_sel][lut_conf_slot] <= lut_conf_data[0];
         end
      end
   end

   // link_enabled CDC
   // Use double register stage for CDC link_enabled signal since the signal is
   // used for reads via the bus.
   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         link_enabled_cdc_0 <= 0;
         link_enabled_cdc_1 <= 0;
      end else begin
         link_enabled_cdc_0 <= link_enabled;
         link_enabled_cdc_1 <= link_enabled_cdc_0;
      end
   end
   assign link_enabled_tile = link_enabled_cdc_1;


   // Start Bus Channels for Endpoints at 1 since Channel 0 gives status info
   generate
      for(j = 0; j < CT_LINKS; j++) begin
         assign noc_in_flit_only[j] = noc_in_flit[j][0 +: FLIT_WIDTH];
         if (PARITY_BITS > 0)
            assign noc_in_parity[j] = noc_in_flit[j][FLIT_WIDTH +: PARITY_BITS];
         else
            assign noc_in_parity[j] = 0;
      end

      for (i = 0; i < CHANNELS; i++) begin : tdm_channel
         ni_tdm_endpoint #(
            .FLIT_WIDTH(FLIT_WIDTH),
            .CT_LINKS(CT_LINKS),
            .LUT_SIZE(LUT_SIZE),
            .BUFFER_DEPTH_IN(BUFFER_DEPTH_IN),
            .BUFFER_DEPTH_OUT(BUFFER_DEPTH_OUT),
            .MAX_LEN(MAX_LEN))
         u_tdm_endpoint (
            .*,               // clk_bus, clk_noc, rst_bus, rst_noc,
                              // bus_addr, bus_we, bus_data_in
            .link_enabled     (link_enabled[i]),
            .link_enabled_tile(link_enabled_tile[i]),
            .out_flit         (channel_out_flit[i]),
            .out_valid        (channel_out_valid[i]),
            .out_checkpoint   (channel_out_checkpoint[i]),
            .rd_select        (channel_rd_select[i]),
            .in_flit          (noc_in_flit_only),
            .in_valid         (noc_in_valid & channel_wr_select[i]),
            .in_checkpoint    (noc_in_last),
            .in_error         (link_error),
            .bus_en           (bus_en & bus_sel_channel[i+1]),
            .bus_data_out     (bus_data_channel[i+1]),
            .bus_ack          (bus_ack_channel[i+1]),
            .bus_err          (bus_err_channel[i+1]),
            .irq              (channel_irq[i])
         );

         for (j = 0; j < CT_LINKS; j++) begin
            assign channel_rd_select[i][j] = (rd_select[j] == i);
            assign channel_wr_select[i][j] = (wr_select[j] == i);
         end
      end

      // TDM Luts, that store the TDM configuration
      for (j = 0; j < CT_LINKS; j++) begin : luts
         tdm_noc_slot_table #(
            .PORTS(LUT_PORTS),
            .LUT_SIZE(LUT_SIZE),
            .OUTPUT_ID(j))
         u_lut_out (
            .*,      // lut_conf_data, lut_conf_sel, lut_conf_slot, lut_conf_valid
            .clk     (clk_noc),
            .rst     (rst_noc),
            .select  (rd_select[j])
         );
         // If an invalid channel is selected, outputs are set to 0
         assign rd_select_valid[j] = (rd_select[j] < CHANNELS);

         tdm_noc_slot_table #(
            .PORTS(LUT_PORTS),
            .LUT_SIZE(LUT_SIZE),
            .OUTPUT_ID(j + CT_LINKS))
         u_lut_in (
            .*,      // lut_conf_data, lut_conf_sel, lut_conf_slot, lut_conf_valid
            .clk     (clk_noc),
            .rst     (rst_noc),
            .select  (wr_select[j])
         );
      end

      // Select output channels depending on select signals from slot tables
      // If an invalid channel is selected, set outputs to 0
      for (j = 0; j < CT_LINKS; j++) begin : output_wiring
         assign out_flit[j] = rd_select_valid[j] ? channel_out_flit[rd_select[j]][j] : 0;
         assign noc_out_valid[j] = rd_select_valid[j] ? channel_out_valid[rd_select[j]][j] : 0;
         assign noc_out_last[j] = rd_select_valid[j] ? channel_out_checkpoint[rd_select[j]][j] : 0;
         assign be_out_enable[j] = ~noc_out_valid[j];
      end

      // Generate FDMs (Fault Detection Modules) for each ingress link
      for (j = 0; j < CT_LINKS; j++) begin : fdms
         if (ENABLE_FDM) begin
            fault_detection_module #(
               .FLIT_WIDTH(FLIT_WIDTH),
               .ROUTER_STAGES(1),
               .FAULTS_PERMANENT(FAULTS_PERMANENT))
            u_fdm (
               .clk        (clk_noc),
               .rst        (rst_noc),
               .in_flit    (noc_in_flit_only[j]),
               .in_valid   (noc_in_valid[j]),
               .in_parity  (noc_in_parity[j]),
               .out_error  (link_error[j])
            );
         end else begin
            assign link_error[j] = 0;
         end
      end

      // Generate a parity encoder for each egress link
      for (j = 0; j < CT_LINKS; j++) begin : pems
         if (ENABLE_FDM && PARITY_BITS != 0) begin
            parity_encoder_module #(
               .FLIT_WIDTH(FLIT_WIDTH))
            u_pem (
               .in_flit    (out_flit[j]),
               .out_flit   (noc_out_flit[j])
            );
         end else begin
            assign noc_out_flit[j] = out_flit[j];
         end
      end
   endgenerate

endmodule // ni_tdm_channels
