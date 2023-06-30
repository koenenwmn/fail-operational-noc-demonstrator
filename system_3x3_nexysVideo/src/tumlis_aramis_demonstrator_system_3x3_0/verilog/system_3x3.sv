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
 * A 3x3 distributed memory system.
 * The system can currently have three different tile types: low performance
 * tiles (LPT), high performance tiles (HPT), and an I/O tile.
 * The tile mapping is determined by the TILE_TYPE parameter.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */

module system_3x3
   import dii_package::dii_flit;
   import optimsoc_config::*;
#(
   parameter config_t CONFIG_LPT = 'x,
   parameter config_t CONFIG_HPT = 'x,
   // Array defining the type of each tile.
   // Type '0' = LPT, Type '1' = HPT, Type '2' = I/O
   parameter [8:0][3:0] TILE_TYPE = 'x,
   parameter LUT_SIZE = 8,
   parameter CT_LINKS = 2,
   parameter MAX_BE_PKT_LEN = 8,
   parameter NUM_BE_ENDPOINTS = 1,
   parameter TDM_MAX_CHECKPOINT_DIST = 8,
   parameter CDC_LPT = 0,
   parameter CDC_HPT = 0,
   parameter ENABLE_DR = 0,
   parameter SIMPLE_NCM = 0,
   parameter ENABLE_FDM_NI = 0,
   parameter ENABLE_FDM_FIM_NOC = 0,
   // Currently hard coded to values needed by demonstrator
   parameter NUM_TDM_EP_LPT = 1,
   parameter NUM_TDM_EP_HPT = 1,
   parameter NUM_TDM_EP_IO = 3,
   localparam TILES = 9,
   // Used to dimension the wires to configure the LUTs.
   // The I/O Tile currently has 8 endpoints.
   localparam MAX_PORTS = NUM_TDM_EP_IO < 6 ? 6 : NUM_TDM_EP_IO
)(
   input             clk_lpt,
   input             clk_hpt,
   input             clk_debug,
   input             clk_noc,
   input             rst,

   glip_channel      c_glip_in,
   glip_channel      c_glip_out,

   output [TILES*32-1:0]   wb_ext_adr_i,
   output [TILES*1-1:0]    wb_ext_cyc_i,
   output [TILES*32-1:0]   wb_ext_dat_i,
   output [TILES*4-1:0]    wb_ext_sel_i,
   output [TILES*1-1:0]    wb_ext_stb_i,
   output [TILES*1-1:0]    wb_ext_we_i,
   output [TILES*1-1:0]    wb_ext_cab_i,
   output [TILES*3-1:0]    wb_ext_cti_i,
   output [TILES*2-1:0]    wb_ext_bte_i,
   input [TILES*1-1:0]     wb_ext_ack_o,
   input [TILES*1-1:0]     wb_ext_rty_o,
   input [TILES*1-1:0]     wb_ext_err_o,
   input [TILES*32-1:0]    wb_ext_dat_o
);

// -----------------------------------------------------------------------------
   // Debug Interface and Ring
   dii_flit [1:0] debug_ring_in [0:TILES];
   dii_flit [1:0] debug_ring_out [0:TILES];
   wire [1:0] debug_ring_in_ready [0:TILES];
   wire [1:0] debug_ring_out_ready [0:TILES];

   wire       rst_sys, rst_cpu, rst_noc;

   // CDC for reset signal into NoC domain
   (* ASYNC_REG = "true" *) reg [1:0] rst_noc_cdc;
   always_ff @(posedge clk_noc)
      {rst_noc_cdc[1], rst_noc_cdc[0]} <= {rst_noc_cdc[0], rst_sys};
   assign rst_noc = rst_noc_cdc[1];

   debug_interface #(
      .SYSTEM_VENDOR_ID          (2),
      .SYSTEM_DEVICE_ID          (2),
      .NUM_MODULES               (num_debug_mods(CONFIG_LPT.NUMTILES) + 1 /* SCM */ + 1 /* NCM */),
      .MAX_PKT_LEN               (CONFIG_LPT.DEBUG_MAX_PKT_LEN),
      .SUBNET_BITS               (CONFIG_LPT.DEBUG_SUBNET_BITS),
      .LOCAL_SUBNET              (CONFIG_LPT.DEBUG_LOCAL_SUBNET),
      .DEBUG_ROUTER_BUFFER_SIZE  (CONFIG_LPT.DEBUG_ROUTER_BUFFER_SIZE))
   u_debuginterface (
      .clk            (clk_debug),
      .rst            (rst),
      .sys_rst        (rst_sys),
      .cpu_rst        (rst_cpu),
      .glip_in        (c_glip_in),
      .glip_out       (c_glip_out),
      .ring_out       (debug_ring_in[3]),
      .ring_out_ready (debug_ring_in_ready[3]),
      .ring_in        (debug_ring_out[9]),
      .ring_in_ready  (debug_ring_out_ready[9])
   );

   // We are routing the debug in a spiral, beginning with the I/O tile.
   // Additionally, the noc control module is added between tile 4 and the
   // debug interface as "10th tile" (index '9').
   assign debug_ring_in[0] = debug_ring_out[3];
   assign debug_ring_out_ready[3] = debug_ring_in_ready[0];
   assign debug_ring_in[1] = debug_ring_out[0];
   assign debug_ring_out_ready[0] = debug_ring_in_ready[1];
   assign debug_ring_in[2] = debug_ring_out[1];
   assign debug_ring_out_ready[1] = debug_ring_in_ready[2];
   assign debug_ring_in[5] = debug_ring_out[2];
   assign debug_ring_out_ready[2] = debug_ring_in_ready[5];
   assign debug_ring_in[8] = debug_ring_out[5];
   assign debug_ring_out_ready[5] = debug_ring_in_ready[8];
   assign debug_ring_in[7] = debug_ring_out[8];
   assign debug_ring_out_ready[8] = debug_ring_in_ready[7];
   assign debug_ring_in[6] = debug_ring_out[7];
   assign debug_ring_out_ready[7] = debug_ring_in_ready[6];
   assign debug_ring_in[4] = debug_ring_out[6];
   assign debug_ring_out_ready[6] = debug_ring_in_ready[4];
   assign debug_ring_in[9] = debug_ring_out[4];
   assign debug_ring_out_ready[4] = debug_ring_in_ready[9];

// -----------------------------------------------------------------------------
   // Hybrid NoC Mesh 3x3
   localparam FLIT_WIDTH = CONFIG_LPT.NOC_FLIT_WIDTH;
   localparam PARITY_BITS = ENABLE_FDM_NI ? FLIT_WIDTH/8 : 0;
   localparam LINK_WIDTH = FLIT_WIDTH + PARITY_BITS;

   // Links: NoC --> Tiles
   wire [TILES-1:0][CT_LINKS-1:0][LINK_WIDTH-1:0]  link_in_flit;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_in_last;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_tdm_in_valid;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_be_in_valid;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_be_in_ready;

   // Links: NoC <-- Tiles
   wire [TILES-1:0][CT_LINKS-1:0][LINK_WIDTH-1:0]  link_out_flit;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_out_last;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_tdm_out_valid;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_be_out_valid;
   wire [TILES-1:0][CT_LINKS-1:0]                  link_be_out_ready;

   // Wires for the NoC control module
   wire [TILES-1:0][7:0]                           fim_enable;
   wire [TILES-1:0][7:0]                           faults;
   wire [TILES-1:0][5:0]                           router_link_error;
   wire [TILES-1:0][1:0]                           ni_link_error;
   wire [TILES-1:0][7:0]                           tdm_util;
   wire [TILES-1:0][7:0]                           be_util;
   // LUT Configuration Interface
   wire [$clog2(MAX_PORTS+1)-1:0]                  lut_conf_data;
   wire [$clog2(MAX_PORTS)-1:0]                    lut_conf_sel;
   wire [$clog2(LUT_SIZE)-1:0]                     lut_conf_slot;
   wire [$clog2(TILES)-1:0]                        config_node;
   wire                                            lut_conf_valid;
   wire                                            lut_conf_valid_ni;
   wire                                            link_en_valid;

   // Wire faults into a single group of wires
   genvar i;
   generate
      for (i = 0; i < TILES; i = i + 1) begin
         assign faults[i] = {ni_link_error[i], router_link_error[i]};
      end
   endgenerate

   hybrid_noc_mesh #(
      .X (3), .Y (3),
      .FLIT_WIDTH       (FLIT_WIDTH),
      .CT_LINKS         (CT_LINKS),
      .LUT_SIZE         (LUT_SIZE),
      .PARITY_BITS      (PARITY_BITS),
      .ENABLE_FDM       (ENABLE_FDM_FIM_NOC),
      .FAULTS_PERMANENT (0),
      .ENABLE_FIM       (ENABLE_FDM_FIM_NOC),
      .ENABLE_DR        (ENABLE_DR),
      .NUM_BE_ENDPOINTS (NUM_BE_ENDPOINTS))
   u_noc (
      .clk              (clk_noc),
      .rst              (rst_noc),

      .in_flit          (link_out_flit),
      .in_last          (link_out_last),
      .tdm_in_valid     (link_tdm_out_valid),
      .be_in_valid      (link_be_out_valid),
      .be_in_ready      (link_be_out_ready),

      .out_flit         (link_in_flit),
      .out_last         (link_in_last),
      .tdm_out_valid    (link_tdm_in_valid),
      .be_out_valid     (link_be_in_valid),
      .be_out_ready     (link_be_in_ready),

      .lut_conf_data    (lut_conf_data[2:0]),
      .lut_conf_sel     (lut_conf_sel[2:0]),
      .lut_conf_slot    (lut_conf_slot),
      .config_node      (config_node),
      .lut_conf_valid   (lut_conf_valid),

      .fim_enable       (fim_enable),
      .out_error        (router_link_error),
      .tdm_util         (tdm_util),
      .be_util          (be_util)
   );

// -----------------------------------------------------------------------------
   // NoC control module wrapper ("10th tile").
   noc_control_module_wrapper #(
      .DEBUG_BASEID ((CONFIG_HPT.DEBUG_LOCAL_SUBNET << (16 - CONFIG_HPT.DEBUG_SUBNET_BITS))
         + 1 + (num_debug_mods(TILES))),
      .X (3), .Y (3),
      .MAX_DI_PKT_LEN   (CONFIG_LPT.DEBUG_MAX_PKT_LEN),
      .LUT_SIZE         (LUT_SIZE),
      .MAX_PORTS        (MAX_PORTS),
      .SIMPLE_NCM       (SIMPLE_NCM),
      .ENABLE_FDM_FIM   (ENABLE_FDM_FIM_NOC))
   u_noc_control_module (
      .clk_debug              (clk_debug),
      .clk_noc                (clk_noc),
      .rst_debug              (rst),
      .rst_noc                (rst_noc),

      .debug_ring_in          (debug_ring_in[9]),
      .debug_ring_in_ready    (debug_ring_in_ready[9]),
      .debug_ring_out         (debug_ring_out[9]),
      .debug_ring_out_ready   (debug_ring_out_ready[9]),
      .lut_conf_data          (lut_conf_data),
      .lut_conf_sel           (lut_conf_sel),
      .lut_conf_slot          (lut_conf_slot),
      .config_node            (config_node),
      .lut_conf_valid         (lut_conf_valid),
      .lut_conf_valid_ni      (lut_conf_valid_ni),
      .link_en_valid          (link_en_valid),
      .fim_en                 (fim_enable),
      .faults                 (faults),
      .tdm_util               (tdm_util),
      .be_util                (be_util)
   );

// -----------------------------------------------------------------------------
   // Generate the Compute Tiles
   // The corresponding value in the TILE_TYPE array defines, whether the tile
   // will be an LPT or an HPT tile.

   generate
      for (i = 0; i < TILES; i = i + 1) begin : gen_tile
         if (TILE_TYPE[i] == 0) begin : gen_lpt
            compute_tile_dm #(
               .CONFIG        (CONFIG_LPT),
               .ID            (i),
               .COREBASE      (corebase_id(i)),
               .DEBUG_BASEID  ((CONFIG_LPT.DEBUG_LOCAL_SUBNET << (16 - CONFIG_LPT.DEBUG_SUBNET_BITS))
                  + 1 + (num_debug_mods(i))),
               .TDM_CHANNELS              (NUM_TDM_EP_LPT),
               .TDM_LUT_SIZE              (LUT_SIZE),
               .TDM_BUFFER_DEPTH_IN       (256),
               .TDM_BUFFER_DEPTH_OUT      (256),
               .TDM_MAX_CHECKPOINT_DIST   (TDM_MAX_CHECKPOINT_DIST),
               .CT_LINKS                  (CT_LINKS),
               .NUM_BE_ENDPOINTS          (NUM_BE_ENDPOINTS),
               .BE_BUFFER_DEPTH           (256),
               .MAX_BE_PKT_LEN            (MAX_BE_PKT_LEN),
               .CDC                       (CDC_LPT),
               .ENABLE_FDM                (ENABLE_FDM_NI),
               .ENABLE_DR                 (ENABLE_DR))
            u_lpt (
               .clk_tile                  (clk_lpt),
               .clk_noc                   (clk_noc),
               .clk_dbg                   (clk_debug),
               .rst_cpu                   (rst_cpu),
               .rst_sys                   (rst_sys),
               .rst_dbg                   (rst),
               .debug_ring_in             (debug_ring_in[i]),
               .debug_ring_in_ready       (debug_ring_in_ready[i]),
               .debug_ring_out            (debug_ring_out[i]),
               .debug_ring_out_ready      (debug_ring_out_ready[i]),

               .wb_ext_ack_o              (wb_ext_ack_o[i]),
               .wb_ext_rty_o              (wb_ext_rty_o[i]),
               .wb_ext_err_o              (wb_ext_err_o[i]),
               .wb_ext_dat_o              (wb_ext_dat_o[(i+1)*32-1:i*32]),
               .wb_ext_adr_i              (wb_ext_adr_i[(i+1)*32-1:i*32]),
               .wb_ext_cyc_i              (wb_ext_cyc_i[i]),
               .wb_ext_dat_i              (wb_ext_dat_i[(i+1)*32-1:i*32]),
               .wb_ext_sel_i              (wb_ext_sel_i[(i+1)*4-1:i*4]),
               .wb_ext_stb_i              (wb_ext_stb_i[i]),
               .wb_ext_we_i               (wb_ext_we_i[i]),
               .wb_ext_cab_i              (wb_ext_cab_i[i]),
               .wb_ext_cti_i              (wb_ext_cti_i[(i+1)*3-1:i*3]),
               .wb_ext_bte_i              (wb_ext_bte_i[(i+1)*2-1:i*2]),

               .noc_out_flit              (link_out_flit[i]),
               .noc_out_last              (link_out_last[i]),
               .noc_tdm_out_valid         (link_tdm_out_valid[i]),
               .noc_be_out_valid          (link_be_out_valid[i]),
               .noc_be_out_ready          (link_be_out_ready[i]),

               .noc_in_flit               (link_in_flit[i]),
               .noc_in_last               (link_in_last[i]),
               .noc_tdm_in_valid          (link_tdm_in_valid[i]),
               .noc_be_in_valid           (link_be_in_valid[i]),
               .noc_be_in_ready           (link_be_in_ready[i]),

               .lut_conf_data             (lut_conf_data),
               .lut_conf_sel              (lut_conf_sel),
               .lut_conf_slot             (lut_conf_slot),
               .lut_conf_valid            (lut_conf_valid_ni && (config_node == i)),
               .link_en_valid             (link_en_valid && (config_node == i)),

               .link_error                (ni_link_error[i])
            );
         end // gen_lpt
         if (TILE_TYPE[i] == 1) begin : gen_hpt
            compute_tile_dm #(
               .CONFIG        (CONFIG_HPT),
               .ID            (i),
               .COREBASE      (corebase_id(i)),
               .DEBUG_BASEID  ((CONFIG_HPT.DEBUG_LOCAL_SUBNET << (16 - CONFIG_HPT.DEBUG_SUBNET_BITS))
                  + 1 + (num_debug_mods(i))),
               .TDM_CHANNELS              (NUM_TDM_EP_HPT),
               .TDM_LUT_SIZE              (LUT_SIZE),
               .TDM_BUFFER_DEPTH_IN       (256),
               .TDM_BUFFER_DEPTH_OUT      (256),
               .TDM_MAX_CHECKPOINT_DIST   (TDM_MAX_CHECKPOINT_DIST),
               .CT_LINKS                  (CT_LINKS),
               .NUM_BE_ENDPOINTS          (NUM_BE_ENDPOINTS),
               .BE_BUFFER_DEPTH           (256),
               .MAX_BE_PKT_LEN            (MAX_BE_PKT_LEN),
               .CDC                       (CDC_HPT),
               .ENABLE_FDM                (ENABLE_FDM_NI),
               .ENABLE_DR                 (ENABLE_DR))
            u_hpt (
               .clk_tile                  (clk_hpt),
               .clk_noc                   (clk_noc),
               .clk_dbg                   (clk_debug),
               .rst_cpu                   (rst_cpu),
               .rst_sys                   (rst_sys),
               .rst_dbg                   (rst),
               .debug_ring_in             (debug_ring_in[i]),
               .debug_ring_in_ready       (debug_ring_in_ready[i]),
               .debug_ring_out            (debug_ring_out[i]),
               .debug_ring_out_ready      (debug_ring_out_ready[i]),

               .wb_ext_ack_o              (wb_ext_ack_o[i]),
               .wb_ext_rty_o              (wb_ext_rty_o[i]),
               .wb_ext_err_o              (wb_ext_err_o[i]),
               .wb_ext_dat_o              (wb_ext_dat_o[(i+1)*32-1:i*32]),
               .wb_ext_adr_i              (wb_ext_adr_i[(i+1)*32-1:i*32]),
               .wb_ext_cyc_i              (wb_ext_cyc_i[i]),
               .wb_ext_dat_i              (wb_ext_dat_i[(i+1)*32-1:i*32]),
               .wb_ext_sel_i              (wb_ext_sel_i[(i+1)*4-1:i*4]),
               .wb_ext_stb_i              (wb_ext_stb_i[i]),
               .wb_ext_we_i               (wb_ext_we_i[i]),
               .wb_ext_cab_i              (wb_ext_cab_i[i]),
               .wb_ext_cti_i              (wb_ext_cti_i[(i+1)*3-1:i*3]),
               .wb_ext_bte_i              (wb_ext_bte_i[(i+1)*2-1:i*2]),

               .noc_out_flit              (link_out_flit[i]),
               .noc_out_last              (link_out_last[i]),
               .noc_tdm_out_valid         (link_tdm_out_valid[i]),
               .noc_be_out_valid          (link_be_out_valid[i]),
               .noc_be_out_ready          (link_be_out_ready[i]),

               .noc_in_flit               (link_in_flit[i]),
               .noc_in_last               (link_in_last[i]),
               .noc_tdm_in_valid          (link_tdm_in_valid[i]),
               .noc_be_in_valid           (link_be_in_valid[i]),
               .noc_be_in_ready           (link_be_in_ready[i]),

               .lut_conf_data             (lut_conf_data),
               .lut_conf_sel              (lut_conf_sel),
               .lut_conf_slot             (lut_conf_slot),
               .lut_conf_valid            (lut_conf_valid_ni && (config_node == i)),
               .link_en_valid             (link_en_valid && (config_node == i)),

               .link_error                (ni_link_error[i])
            );
         end // gen_hpt
         if (TILE_TYPE[i] == 2) begin : gen_io
            io_tile_hybrid #(
               .CONFIG        (CONFIG_LPT),
               .ID            (i),
               .DEBUG_BASEID  ((CONFIG_LPT.DEBUG_LOCAL_SUBNET << (16 - CONFIG_LPT.DEBUG_SUBNET_BITS))
                  + 1 + (num_debug_mods(i))),
               .TDM_CHANNELS              (NUM_TDM_EP_IO),
               .TDM_LUT_SIZE              (LUT_SIZE),
               .TDM_BUFFER_DEPTH_IN       (256),
               .TDM_BUFFER_DEPTH_OUT      (256),
               .TDM_MAX_CHECKPOINT_DIST   (TDM_MAX_CHECKPOINT_DIST),
               .CT_LINKS                  (CT_LINKS),
               .NUM_BE_ENDPOINTS          (NUM_BE_ENDPOINTS),
               .BE_BUFFER_DEPTH           (256),
               .MAX_BE_PKT_LEN            (MAX_BE_PKT_LEN),
               .INGRESS_BUFFER_SIZE       (4096),
               .EGRESS_BUFFER_SIZE        (32),
               .ENABLE_FDM                (ENABLE_FDM_NI),
               .ENABLE_DR                 (ENABLE_DR))
            u_io (
               .clk_debug                 (clk_debug),
               .clk_noc                   (clk_noc),
               .rst_debug                 (rst),
               .rst_sys                   (rst_sys),

               .debug_ring_in             (debug_ring_in[i]),
               .debug_ring_in_ready       (debug_ring_in_ready[i]),
               .debug_ring_out            (debug_ring_out[i]),
               .debug_ring_out_ready      (debug_ring_out_ready[i]),

               .noc_in_flit               (link_in_flit[i]),
               .noc_in_last               (link_in_last[i]),
               .noc_tdm_in_valid          (link_tdm_in_valid[i]),
               .noc_be_in_valid           (link_be_in_valid[i]),
               .noc_be_in_ready           (link_be_in_ready[i]),

               .noc_out_flit              (link_out_flit[i]),
               .noc_out_last              (link_out_last[i]),
               .noc_tdm_out_valid         (link_tdm_out_valid[i]),
               .noc_be_out_valid          (link_be_out_valid[i]),
               .noc_be_out_ready          (link_be_out_ready[i]),

               .lut_conf_data             (lut_conf_data),
               .lut_conf_sel              (lut_conf_sel),
               .lut_conf_slot             (lut_conf_slot),
               .lut_conf_valid            (lut_conf_valid_ni && (config_node == i)),
               .link_en_valid             (link_en_valid && (config_node == i)),

               .link_error                (ni_link_error[i])
            );
            // Set unused wishbone signals to '0'
            assign wb_ext_adr_i[(i+1)*32-1:i*32] = 0;
            assign wb_ext_cyc_i[i] = 0;
            assign wb_ext_dat_i[(i+1)*32-1:i*32] = 0;
            assign wb_ext_sel_i[(i+1)*4-1:i*4] = 0;
            assign wb_ext_stb_i[i] = 0;
            assign wb_ext_we_i[i] = 0;
            assign wb_ext_cab_i[i] = 0;
            assign wb_ext_cti_i[(i+1)*3-1:i*3] = 0;
            assign wb_ext_bte_i[(i+1)*2-1:i*2] = 0;
         end // gen_io
      end // gen_tile
   endgenerate


// -----------------------------------------------------------------------------
   // FUNCTIONS

   function integer num_debug_mods(input integer idx);
      integer i;
      num_debug_mods = 0;
      for (i = 0; i < idx; i++) begin
         // LPT
         if (TILE_TYPE[i] == 0)
            num_debug_mods = num_debug_mods + CONFIG_LPT.DEBUG_MODS_PER_TILE;
         // HPT
         else if (TILE_TYPE[i] == 1)
            num_debug_mods = num_debug_mods + CONFIG_HPT.DEBUG_MODS_PER_TILE;
         // I/O
         else if (TILE_TYPE[i] == 2)
            num_debug_mods = num_debug_mods + 2;
      end
   endfunction

   function integer corebase_id(input integer idx);
      integer i;
      corebase_id = 0;
      for (i = 0; i < idx; i++) begin
         if (TILE_TYPE[i] == 0)
            corebase_id = corebase_id + CONFIG_LPT.CORES_PER_TILE;
         else if (TILE_TYPE[i] == 1)
            corebase_id = corebase_id + CONFIG_HPT.CORES_PER_TILE;
      end
   endfunction
endmodule // system_3x3
