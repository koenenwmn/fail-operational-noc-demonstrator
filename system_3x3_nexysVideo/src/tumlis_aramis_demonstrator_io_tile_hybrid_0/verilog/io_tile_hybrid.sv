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
 * I/O tile for a hybrid NoC.
 *
 * Author(s):
 *   Stefan Keller <stefan.keller@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 *   Max Koenen <max.koenen@tum.de>
 */
import dii_package::dii_flit;
import optimsoc_config::*;

module io_tile_hybrid #(
   parameter config_t CONFIG           = 'x,
   parameter ID                        = 'x,
   parameter DEBUG_BASEID              = 'x,

   parameter DI_FLIT_WIDTH             = 16,

   parameter CT_LINKS                  = 2,
   parameter NUM_BE_ENDPOINTS          = 2,

   parameter TDM_LUT_SIZE              = 4,
   parameter TDM_CHANNELS              = 4,
   parameter TDM_BUFFER_DEPTH_IN       = 16,
   parameter TDM_BUFFER_DEPTH_OUT      = 16,
   parameter TDM_MAX_CHECKPOINT_DIST   = 8,
   parameter BE_BUFFER_DEPTH           = 16,
   parameter MAX_BE_PKT_LEN            = 8,

   parameter INGRESS_BUFFER_SIZE       = 32, // Size of the di_na_bridge ingress buffer in bytes
   parameter EGRESS_BUFFER_SIZE        = 32, // Size of the di_na_bridge egress buffer in bytes

   parameter ENABLE_FDM                = 1,
   parameter ENABLE_DR                 = 0,

   localparam MAX_DI_PKT_LEN           = CONFIG.DEBUG_MAX_PKT_LEN,
   localparam CHANNELS                 = CONFIG.NOC_CHANNELS,
   localparam NUM_TILES                = CONFIG.NUMTILES,
   localparam NOC_FLIT_WIDTH           = 32,
   localparam NOC_PARITY_WIDTH         = ENABLE_FDM ? NOC_FLIT_WIDTH / 8 : 0,
   localparam NOC_LINK_WIDTH           = NOC_FLIT_WIDTH + NOC_PARITY_WIDTH,
   localparam NUM_DEBUG_MODULES        = 2   // currently hard coded for this module
)(
   input                                     clk_debug,
   input                                     clk_noc,
   input                                     rst_debug,
   input                                     rst_sys,

   input dii_flit [1:0]                      debug_ring_in,
   output [1:0]                              debug_ring_in_ready,
   output dii_flit [1:0]                     debug_ring_out,
   input [1:0]                               debug_ring_out_ready,

   input [CHANNELS-1:0][NOC_LINK_WIDTH-1:0]  noc_in_flit,
   input [CHANNELS-1:0]                      noc_in_last,
   input [CHANNELS-1:0]                      noc_tdm_in_valid,
   input [CHANNELS-1:0]                      noc_be_in_valid,
   output [CHANNELS-1:0]                     noc_be_in_ready,

   output [CHANNELS-1:0][NOC_LINK_WIDTH-1:0] noc_out_flit,
   output [CHANNELS-1:0]                     noc_out_last,
   output [CHANNELS-1:0]                     noc_tdm_out_valid,
   output [CHANNELS-1:0]                     noc_be_out_valid,
   input [CHANNELS-1:0]                      noc_be_out_ready,

   input [$clog2(TDM_CHANNELS+1)-1:0]        lut_conf_data,
   input [$clog2(TDM_CHANNELS)-1:0]          lut_conf_sel,
   input [$clog2(TDM_LUT_SIZE)-1:0]          lut_conf_slot,
   input                                     lut_conf_valid,
   input                                     link_en_valid,

   output [CHANNELS-1:0]                     link_error
);

   // dii signals from surveillance module cdc and bridge to debug_ring_expand
   wire [1:0]     dii_in_ready;
   dii_flit [1:0] dii_in;

   // dii signals from debug_ring_expand to bridge and surveillance module cdc
   wire [1:0]     dii_out_ready;
   dii_flit [1:0] dii_out;

   // WB signals from NA to di_na_bridge
   wire        bussl_ack_o;
   wire        bussl_rty_o;
   wire        bussl_err_o;
   wire [31:0] bussl_dat_o;
   wire [3:0]  irq_ni;

   // WB signals from di_na_bridge to NA
   wire [31:0] bussl_adr_i;
   wire        bussl_cyc_i;
   wire [31:0] bussl_dat_i;
   wire [3:0]  bussl_sel_i;
   wire        bussl_stb_i;
   wire        bussl_we_i;
   wire        bussl_cab_i;
   wire [2:0]  bussl_cti_i;
   wire [1:0]  bussl_bte_i;

   // CDC for reset signal into NoC domain
   (* ASYNC_REG = "true" *) reg [1:0] rst_noc;
   always_ff @(posedge clk_noc)
      {rst_noc[1], rst_noc[0]} <= {rst_noc[0], rst_sys};

// -----------------------------------------------------------------------------

   genvar i;
   logic [NUM_DEBUG_MODULES-1:0][15:0] id_map;
   for (i = 0; i < NUM_DEBUG_MODULES; i = i+1) begin
      assign id_map[i][15:0] = 16'(DEBUG_BASEID+i);
   end
   debug_ring_expand #(
      .BUFFER_SIZE               (CONFIG.DEBUG_ROUTER_BUFFER_SIZE),
      .PORTS                     (2))
   u_debug_ring_segment(
      .clk                       (clk_debug),
      .rst                       (rst_debug),
      .id_map                    (id_map),
      .dii_in                    (dii_in),
      .dii_in_ready              (dii_in_ready),
      .dii_out                   (dii_out),
      .dii_out_ready             (dii_out_ready),
      .ext_in                    (debug_ring_in),
      .ext_in_ready              (debug_ring_in_ready),
      .ext_out                   (debug_ring_out),
      .ext_out_ready             (debug_ring_out_ready)
   );


   di_na_bridge #(
      .TILEID                    (ID),
      .NOC_FLIT_WIDTH            (NOC_FLIT_WIDTH),
      .DI_FLIT_WIDTH             (DI_FLIT_WIDTH),
      .MAX_DI_PKT_LEN            (MAX_DI_PKT_LEN),
      .MAX_BE_PKT_LEN            (MAX_BE_PKT_LEN),
      .TDM_MAX_CHECKPOINT_DIST   (TDM_MAX_CHECKPOINT_DIST),
      .NUM_BE_ENDPOINTS          (NUM_BE_ENDPOINTS),
      .CT_LINKS                  (CT_LINKS),
      .NUM_TDM_ENDPOINTS         (TDM_CHANNELS),
      .INGRESS_BUFFER_SIZE       (INGRESS_BUFFER_SIZE),
      .EGRESS_BUFFER_SIZE        (EGRESS_BUFFER_SIZE),
      .ENABLE_DR                 (ENABLE_DR))
   u_di_na_bridge(
      .id                        (16'(DEBUG_BASEID)),
      .clk                       (clk_debug),
      .irq_tdm                   (irq_ni[2]),
      .irq_be                    (irq_ni[0]),
      .rst_debug                 (rst_debug),
      .rst_sys                   (rst_sys),

      .debug_in_ready            (dii_out_ready[0]),
      .debug_in                  (dii_out[0]),
      .debug_out_ready           (dii_in_ready[0]),
      .debug_out                 (dii_in[0]),

      //wb signals: input from NA
      .wb_ack_i                  (bussl_ack_o),
      .wb_dat_i                  (bussl_dat_o),
      .wb_err_i                  (bussl_err_o),

      //wb signals: output to NA
      .wb_adr_o                  (bussl_adr_i),
      .wb_dat_o                  (bussl_dat_i),
      .wb_we_o                   (bussl_we_i),
      .wb_sel_o                  (bussl_sel_i),
      .wb_stb_o                  (bussl_stb_i),
      .wb_cyc_o                  (bussl_cyc_i)
   );


   hybrid_noc_ni #(
      .CONFIG                    (CONFIG),
      .TILEID                    (ID),
      .COREBASE                  ('b0),
      .CT_LINKS                  (CT_LINKS),
      .LUT_SIZE                  (TDM_LUT_SIZE),
      .TDM_CHANNELS              (TDM_CHANNELS),
      .TDM_BUFFER_DEPTH_IN       (TDM_BUFFER_DEPTH_IN),
      .TDM_BUFFER_DEPTH_OUT      (TDM_BUFFER_DEPTH_OUT),
      .TDM_MAX_CHECKPOINT_DIST   (TDM_MAX_CHECKPOINT_DIST),
      .BE_BUFFER_DEPTH           (BE_BUFFER_DEPTH),
      .MAX_BE_PKT_LEN            (MAX_BE_PKT_LEN),
      .NUM_BE_ENDPOINTS          (NUM_BE_ENDPOINTS),
      .ENABLE_FDM                (ENABLE_FDM),
      .ENABLE_DR                 (ENABLE_DR))
   u_ni(
      .clk_bus                   (clk_debug),
      .clk_noc                   (clk_noc),
      .rst_bus                   (rst_sys),
      .rst_noc                   (rst_noc[1]),

      .in_flit                   (noc_in_flit),
      .in_last                   (noc_in_last),
      .tdm_in_valid              (noc_tdm_in_valid),
      .be_in_valid               (noc_be_in_valid),
      .be_in_ready               (noc_be_in_ready),
      .link_error                (link_error),

      .out_flit                  (noc_out_flit),
      .out_last                  (noc_out_last),
      .tdm_out_valid             (noc_tdm_out_valid),
      .be_out_valid              (noc_be_out_valid),
      .be_out_ready              (noc_be_out_ready),

      .wb_addr                   (bussl_adr_i),
      .wb_cyc                    (bussl_cyc_i),
      .wb_data_in                (bussl_dat_i),
      .wb_sel                    (bussl_sel_i),
      .wb_stb                    (bussl_stb_i),
      .wb_we                     (bussl_we_i),
      .wb_cab                    (bussl_cab_i),
      .wb_cti                    (bussl_cti_i),
      .wb_bte                    (bussl_bte_i),
      .wb_ack                    (bussl_ack_o),
      .wb_rty                    (bussl_rty_o),
      .wb_err                    (bussl_err_o),
      .wb_data_out               (bussl_dat_o),

      .irq                       (irq_ni),

      .lut_conf_data             (lut_conf_data),
      .lut_conf_sel              (lut_conf_sel),
      .lut_conf_slot             (lut_conf_slot),
      .lut_conf_valid            (lut_conf_valid),
      .link_en_valid             (link_en_valid)
   );


   surveillance_module #(
      .MAX_LEN          (MAX_BE_PKT_LEN > TDM_MAX_CHECKPOINT_DIST ? MAX_BE_PKT_LEN : TDM_MAX_CHECKPOINT_DIST),
      .NUM_TDM_ENDPOINTS(TDM_CHANNELS),
      .NUM_TILES        (NUM_TILES),
      .MAX_DI_PKT_LEN   (MAX_DI_PKT_LEN),
      .ID               (ID))
   u_surveillance_module(
      .clk              (clk_debug),
      .rst_dbg          (rst_debug),
      .rst_sys          (rst_sys),

      // wires between wb and na
      .wb_na_addr       (bussl_adr_i),
      .wb_na_data_in    (bussl_dat_i), // sent data
      .wb_na_data_out   (bussl_dat_o), // received data
      .wb_na_we         (bussl_we_i),
      .wb_na_cyc        (bussl_cyc_i),
      .wb_na_stb        (bussl_stb_i),
      .wb_na_ack        (bussl_ack_o),

      // debug i/o
      .debug_in         (dii_out[1]),
      .debug_in_ready   (dii_out_ready[1]),
      .debug_out        (dii_in[1]),
      .debug_out_ready  (dii_in_ready[1]),

      // ports to wb
      .wb_addr            ('b0), // Not used for the I/O tile
      .wb_cyc             ('b0), //
      .wb_data_in         ('b0), //
      .wb_sel             ('b0), //
      .wb_stb             ('b0), //
      .wb_we              ('b0), //
      .wb_cab             ('b0), //
      .wb_cti             ('b0), //
      .wb_bte             ('b0), //
      .wb_ack             (),    //
      .wb_rty             (),    //
      .wb_err             (),    //
      .wb_data_out        (),    //

      .irq  (),                  // Not used for the I/O tile
      .id   (16'(DEBUG_BASEID + 1))
   );

endmodule // io_tile_hybrid
