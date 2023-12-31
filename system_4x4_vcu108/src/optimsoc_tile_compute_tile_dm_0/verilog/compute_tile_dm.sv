/* Copyright (c) 2013-2021 by the author(s)
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
 * This is the compute tile for distributed memory systems, using the Network
 * Interface for the Hybrid TDM NoC. Right now, DMA is not supported. It also
 * includes a surveillance module.
 *
 * The assignment of the 32 bit IRQ vector connected to core 0 is as follows:
 *  - Bit [1:0]:  N/A
 *  - Bit 2:      UART
 *  - Bit 3:      NA - message passing
 *  - Bit 4:      NA - DMA
 *  - Bit 5:      NA - TDM
 *  - Bit 7:      SM
 *  - Bit [31:8]: N/A
 *
 * The address ranges of the bus slaves are as follows:
 *  - Slave 0 - DM:     0x00000000-0x7fffffff
 *  - Slave 1 - PGAS:   not used
 *  - Slave 2 - NA:     0xe0000000-0xefffffff
 *  - Slave 3 - BOOT:   0xf0000000-0xffffffff
 *  - Slave 4 - UART:   0x90000000-0x9000000f
 *  - Slave 5 - SM:     0xa0000000-0xa000ffff
 *
 * TODO: - wire link_error from NI as a compute_tile output
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 *   Stefan Wallentowitz <stefan@wallentowitz.de>
 */

module compute_tile_dm
   import dii_package::dii_flit;
   import opensocdebug::mor1kx_trace_exec;
   import optimsoc_config::*;
#(
   parameter config_t CONFIG           = 'x,
   parameter ID                        = 'x,
   parameter COREBASE                  = 'x,
   parameter DEBUG_BASEID              = 'x,
   parameter MEM_FILE                  = 'x,
   parameter TDM_LUT_SIZE              = 4,
   parameter TDM_CHANNELS              = 4,
   parameter TDM_BUFFER_DEPTH_IN       = 16,
   parameter TDM_BUFFER_DEPTH_OUT      = 16,
   parameter TDM_MAX_CHECKPOINT_DIST   = 8,
   parameter BE_BUFFER_DEPTH           = 16,
   parameter MAX_BE_PKT_LEN            = 8,
   parameter CT_LINKS                  = 2,
   parameter NUM_BE_ENDPOINTS          = 2,
   parameter CDC                       = 0,
   parameter ENABLE_FDM                = 1,
   parameter ENABLE_DR                 = 0,

   localparam FLIT_WIDTH   = CONFIG.NOC_FLIT_WIDTH,
   localparam PARITY_BITS  = ENABLE_FDM ? FLIT_WIDTH/8 : 0,
   localparam LINK_WIDTH   = FLIT_WIDTH + PARITY_BITS
)
(
   input                                  clk_tile, clk_noc, clk_dbg,
   input                                  rst_cpu, rst_sys, rst_dbg,

   input dii_flit [1:0]                   debug_ring_in,
   output [1:0]                           debug_ring_in_ready,
   output dii_flit [1:0]                  debug_ring_out,
   input [1:0]                            debug_ring_out_ready,

   output [31:0]                          wb_ext_adr_i,
   output                                 wb_ext_cyc_i,
   output [31:0]                          wb_ext_dat_i,
   output [3:0]                           wb_ext_sel_i,
   output                                 wb_ext_stb_i,
   output                                 wb_ext_we_i,
   output                                 wb_ext_cab_i,
   output [2:0]                           wb_ext_cti_i,
   output [1:0]                           wb_ext_bte_i,
   input                                  wb_ext_ack_o,
   input                                  wb_ext_rty_o,
   input                                  wb_ext_err_o,
   input [31:0]                           wb_ext_dat_o,

   input [CT_LINKS-1:0][LINK_WIDTH-1:0]   noc_in_flit,
   input [CT_LINKS-1:0]                   noc_in_last,
   input [CT_LINKS-1:0]                   noc_tdm_in_valid,
   input [CT_LINKS-1:0]                   noc_be_in_valid,
   output [CT_LINKS-1:0]                  noc_be_in_ready,

   output [CT_LINKS-1:0][LINK_WIDTH-1:0]  noc_out_flit,
   output [CT_LINKS-1:0]                  noc_out_last,
   output [CT_LINKS-1:0]                  noc_tdm_out_valid,
   output [CT_LINKS-1:0]                  noc_be_out_valid,
   input [CT_LINKS-1:0]                   noc_be_out_ready,

   input [$clog2(TDM_CHANNELS+1)-1:0]     lut_conf_data,
   input [$clog2(TDM_CHANNELS)-1:0]       lut_conf_sel,
   input [$clog2(TDM_LUT_SIZE)-1:0]       lut_conf_slot,
   input                                  lut_conf_valid,
   // Same interface is used to enable links for outgoing channels
   input                                  link_en_valid,

   output [CT_LINKS-1:0]                  link_error
);

   import optimsoc_functions::*;
   mor1kx_trace_exec [CONFIG.CORES_PER_TILE-1:0] trace;

   localparam NR_MASTERS = CONFIG.CORES_PER_TILE * 2 + 1;
   localparam NR_SLAVES = 6;
   localparam SLAVE_DM   = 0;
   localparam SLAVE_PGAS = 1;
   localparam SLAVE_NA   = 2;
   localparam SLAVE_BOOT = 3;
   localparam SLAVE_UART = 4;
   localparam SLAVE_SM   = 5;

// -----------------------------------------------------------------------------
   // WB Bus Master and Slave signals - hierarchical
   wire [31:0]              busms_adr_o[0:NR_MASTERS-1];
   wire                     busms_cyc_o[0:NR_MASTERS-1];
   wire [31:0]              busms_dat_o[0:NR_MASTERS-1];
   wire [3:0]               busms_sel_o[0:NR_MASTERS-1];
   wire                     busms_stb_o[0:NR_MASTERS-1];
   wire                     busms_we_o[0:NR_MASTERS-1];
   wire                     busms_cab_o[0:NR_MASTERS-1];
   wire [2:0]               busms_cti_o[0:NR_MASTERS-1];
   wire [1:0]               busms_bte_o[0:NR_MASTERS-1];
   wire                     busms_ack_i[0:NR_MASTERS-1];
   wire                     busms_rty_i[0:NR_MASTERS-1];
   wire                     busms_err_i[0:NR_MASTERS-1];
   wire [31:0]              busms_dat_i[0:NR_MASTERS-1];

   wire [31:0]              bussl_adr_i[0:NR_SLAVES-1];
   wire                     bussl_cyc_i[0:NR_SLAVES-1];
   wire [31:0]              bussl_dat_i[0:NR_SLAVES-1];
   wire [3:0]               bussl_sel_i[0:NR_SLAVES-1];
   wire                     bussl_stb_i[0:NR_SLAVES-1];
   wire                     bussl_we_i[0:NR_SLAVES-1];
   wire                     bussl_cab_i[0:NR_SLAVES-1];
   wire [2:0]               bussl_cti_i[0:NR_SLAVES-1];
   wire [1:0]               bussl_bte_i[0:NR_SLAVES-1];
   wire                     bussl_ack_o[0:NR_SLAVES-1];
   wire                     bussl_rty_o[0:NR_SLAVES-1];
   wire                     bussl_err_o[0:NR_SLAVES-1];
   wire [31:0]              bussl_dat_o[0:NR_SLAVES-1];

   // WB Bus Master and Slave signals - flattened
   wire [32*NR_MASTERS-1:0] busms_adr_o_flat;
   wire [NR_MASTERS-1:0]    busms_cyc_o_flat;
   wire [32*NR_MASTERS-1:0] busms_dat_o_flat;
   wire [4*NR_MASTERS-1:0]  busms_sel_o_flat;
   wire [NR_MASTERS-1:0]    busms_stb_o_flat;
   wire [NR_MASTERS-1:0]    busms_we_o_flat;
   wire [NR_MASTERS-1:0]    busms_cab_o_flat;
   wire [3*NR_MASTERS-1:0]  busms_cti_o_flat;
   wire [2*NR_MASTERS-1:0]  busms_bte_o_flat;
   wire [NR_MASTERS-1:0]    busms_ack_i_flat;
   wire [NR_MASTERS-1:0]    busms_rty_i_flat;
   wire [NR_MASTERS-1:0]    busms_err_i_flat;
   wire [32*NR_MASTERS-1:0] busms_dat_i_flat;

   wire [32*NR_SLAVES-1:0]  bussl_adr_i_flat;
   wire [NR_SLAVES-1:0]     bussl_cyc_i_flat;
   wire [32*NR_SLAVES-1:0]  bussl_dat_i_flat;
   wire [4*NR_SLAVES-1:0]   bussl_sel_i_flat;
   wire [NR_SLAVES-1:0]     bussl_stb_i_flat;
   wire [NR_SLAVES-1:0]     bussl_we_i_flat;
   wire [NR_SLAVES-1:0]     bussl_cab_i_flat;
   wire [3*NR_SLAVES-1:0]   bussl_cti_i_flat;
   wire [2*NR_SLAVES-1:0]   bussl_bte_i_flat;
   wire [NR_SLAVES-1:0]     bussl_ack_o_flat;
   wire [NR_SLAVES-1:0]     bussl_rty_o_flat;
   wire [NR_SLAVES-1:0]     bussl_err_o_flat;
   wire [32*NR_SLAVES-1:0]  bussl_dat_o_flat;

   // WB Bus for Direct Memory Accesses
   // Only used, when CONFIG.ENABLE_DM = 1
   logic                    wb_mem_clk_i;
   logic                    wb_mem_rst_i;
   logic [31:0]             wb_mem_adr_i;
   logic                    wb_mem_cyc_i;
   logic [31:0]             wb_mem_dat_i;
   logic [3:0]              wb_mem_sel_i;
   logic                    wb_mem_stb_i;
   logic                    wb_mem_we_i;
   logic                    wb_mem_cab_i;
   logic [2:0]              wb_mem_cti_i;
   logic [1:0]              wb_mem_bte_i;
   logic                    wb_mem_ack_o;
   logic                    wb_mem_rty_o;
   logic                    wb_mem_err_o;
   logic [31:0]             wb_mem_dat_o;

   // Memory Access Module - Wishbone Adapter signals
   logic                    mam_dm_stb_o;
   logic                    mam_dm_cyc_o;
   logic                    mam_dm_ack_i;
   logic                    mam_dm_err_i;
   logic                    mam_dm_rty_i;
   logic                    mam_dm_we_o;
   logic [31:0]             mam_dm_addr_o;
   logic [31:0]             mam_dm_dat_o;
   logic [31:0]             mam_dm_dat_i;
   logic [2:0]              mam_dm_cti_o;
   logic [1:0]              mam_dm_bte_o;
   logic [3:0]              mam_dm_sel_o;

   wire                     snoop_enable;
   wire [31:0]              snoop_adr;

   // Interrupt Requests
   wire [31:0]              pic_ints_i [0:CONFIG.CORES_PER_TILE-1];

// -----------------------------------------------------------------------------
   // Create DI ring segment with routers
   localparam DEBUG_MODS_PER_TILE_NONZERO = (CONFIG.DEBUG_MODS_PER_TILE == 0) ? 1 : CONFIG.DEBUG_MODS_PER_TILE;

   dii_flit [DEBUG_MODS_PER_TILE_NONZERO-1:0]   dii_in;
   logic [DEBUG_MODS_PER_TILE_NONZERO-1:0]      dii_in_ready;
   dii_flit [DEBUG_MODS_PER_TILE_NONZERO-1:0]   dii_out;
   logic [DEBUG_MODS_PER_TILE_NONZERO-1:0]      dii_out_ready;

   // CDC wires
   dii_flit [DEBUG_MODS_PER_TILE_NONZERO-1:0]   cdc_dii_in;
   logic [DEBUG_MODS_PER_TILE_NONZERO-1:0]      cdc_dii_in_ready;
   dii_flit [DEBUG_MODS_PER_TILE_NONZERO-1:0]   cdc_dii_out;
   logic [DEBUG_MODS_PER_TILE_NONZERO-1:0]      cdc_dii_out_ready;

   // Internal reset signals
   wire rst_core;
   wire rst_tile;
   wire rst_noc;
   wire rst_debug;

   // Reset signal CDC
   // Currently, CDC is always enabled in the NI
   (* ASYNC_REG = "true" *) reg [1:0]   rst_sys_noc_cdc;
   always_ff @(posedge clk_noc)
      {rst_sys_noc_cdc[1], rst_sys_noc_cdc[0]} <= {rst_sys_noc_cdc[0], rst_sys};
   assign rst_noc = rst_sys_noc_cdc[1];

   generate
      if (CONFIG.USE_DEBUG == 1) begin : gen_debug_ring
         genvar i;
         logic [CONFIG.DEBUG_MODS_PER_TILE-1:0][15:0] id_map;
         for (i = 0; i < CONFIG.DEBUG_MODS_PER_TILE; i = i+1) begin
            assign id_map[i][15:0] = 16'(DEBUG_BASEID+i);
         end

         debug_ring_expand #(
            .BUFFER_SIZE(CONFIG.DEBUG_ROUTER_BUFFER_SIZE),
            .PORTS(CONFIG.DEBUG_MODS_PER_TILE))
         u_debug_ring_segment(
            .clk           (clk_dbg),
            .rst           (rst_dbg),
            .id_map        (id_map),
            .dii_in        (cdc_dii_in),
            .dii_in_ready  (cdc_dii_in_ready),
            .dii_out       (cdc_dii_out),
            .dii_out_ready (cdc_dii_out_ready),
            .ext_in        (debug_ring_in),
            .ext_in_ready  (debug_ring_in_ready),
            .ext_out       (debug_ring_out),
            .ext_out_ready (debug_ring_out_ready)
         );
      end // if (USE_DEBUG)
   endgenerate

   generate
      if (CDC == 1) begin : cdc_fifos
         // Reset signal CDC
         (* ASYNC_REG = "true" *) reg [1:0]   rst_cpu_cdc;
         (* ASYNC_REG = "true" *) reg [1:0]   rst_sys_tile_cdc;
         (* ASYNC_REG = "true" *) reg [1:0]   rst_dbg_cdc;
         always_ff @(posedge clk_tile) begin
            {rst_cpu_cdc[1], rst_cpu_cdc[0]} <= {rst_cpu_cdc[0], rst_cpu};
            {rst_sys_tile_cdc[1], rst_sys_tile_cdc[0]} <= {rst_sys_tile_cdc[0], rst_sys};
            {rst_dbg_cdc[1], rst_dbg_cdc[0]} <= {rst_dbg_cdc[0], rst_dbg};
         end
         assign rst_core = rst_cpu_cdc[1];
         assign rst_tile = rst_sys_tile_cdc[1];
         assign rst_debug = rst_dbg_cdc[1];

         wire [DEBUG_MODS_PER_TILE_NONZERO-1:0]       in_cdc_full;
         wire [DEBUG_MODS_PER_TILE_NONZERO-1:0]       in_cdc_empty;
         wire [DEBUG_MODS_PER_TILE_NONZERO-1:0]       out_cdc_full;
         wire [DEBUG_MODS_PER_TILE_NONZERO-1:0]       out_cdc_empty;

         genvar i;
         for (i = 0; i < DEBUG_MODS_PER_TILE_NONZERO; i++) begin
            // Cross into tile clock domain
            assign cdc_dii_out_ready[i] = ~in_cdc_full[i];
            fifo_dualclock_fwft #(
               .WIDTH(17),
               .DEPTH(16))
            u_cdc_in (
               .wr_clk     (clk_dbg),
               .wr_rst     (rst_dbg),
               .wr_en      (cdc_dii_out[i].valid),
               .din        ({cdc_dii_out[i].last, cdc_dii_out[i].data}),

               .rd_clk     (clk_tile),
               .rd_rst     (rst_debug),
               .rd_en      (dii_out_ready[i]),
               .dout       ({dii_out[i].last, dii_out[i].data}),

               .full       (in_cdc_full[i]),
               .prog_full  (),
               .empty      (in_cdc_empty[i]),
               .prog_empty ()
            );
            assign dii_out[i].valid = ~in_cdc_empty[i];

            // Cross into debug ring clock domain
            assign dii_in_ready[i] = ~out_cdc_full[i];
            fifo_dualclock_fwft #(
               .WIDTH(17),
               .DEPTH(16))
            u_cdc_out (
               .wr_clk     (clk_tile),
               .wr_rst     (rst_debug),
               .wr_en      (dii_in[i].valid),
               .din        ({dii_in[i].last, dii_in[i].data}),

               .rd_clk     (clk_dbg),
               .rd_rst     (rst_dbg),
               .rd_en      (cdc_dii_in_ready[i]),
               .dout       ({cdc_dii_in[i].last, cdc_dii_in[i].data}),

               .full       (out_cdc_full[i]),
               .prog_full  (),
               .empty      (out_cdc_empty[i]),
               .prog_empty ()
            );
            assign cdc_dii_in[i].valid = ~out_cdc_empty[i];
         end
      end else begin
         assign rst_core = rst_cpu;
         assign rst_tile = rst_sys;
         assign rst_debug = rst_dbg;
         assign dii_out = cdc_dii_out;
         assign cdc_dii_out_ready = dii_out_ready;
         assign cdc_dii_in = dii_in;
         assign dii_in_ready = cdc_dii_in_ready;
      end
   endgenerate

// -----------------------------------------------------------------------------
  // Wire flattened and non flattened busses
   genvar c, m, s;
   generate
      for (m = 0; m < NR_MASTERS; m = m + 1) begin : gen_busms_flat
         assign busms_adr_o_flat[32*(m+1)-1:32*m] = busms_adr_o[m];
         assign busms_cyc_o_flat[m] = busms_cyc_o[m];
         assign busms_dat_o_flat[32*(m+1)-1:32*m] = busms_dat_o[m];
         assign busms_sel_o_flat[4*(m+1)-1:4*m] = busms_sel_o[m];
         assign busms_stb_o_flat[m] = busms_stb_o[m];
         assign busms_we_o_flat[m] = busms_we_o[m];
         assign busms_cab_o_flat[m] = busms_cab_o[m];
         assign busms_cti_o_flat[3*(m+1)-1:3*m] = busms_cti_o[m];
         assign busms_bte_o_flat[2*(m+1)-1:2*m] = busms_bte_o[m];
         assign busms_ack_i[m] = busms_ack_i_flat[m];
         assign busms_rty_i[m] = busms_rty_i_flat[m];
         assign busms_err_i[m] = busms_err_i_flat[m];
         assign busms_dat_i[m] = busms_dat_i_flat[32*(m+1)-1:32*m];
      end

      for (s = 0; s < NR_SLAVES; s = s + 1) begin : gen_bussl_flat
         assign bussl_adr_i[s] = bussl_adr_i_flat[32*(s+1)-1:32*s];
         assign bussl_cyc_i[s] = bussl_cyc_i_flat[s];
         assign bussl_dat_i[s] = bussl_dat_i_flat[32*(s+1)-1:32*s];
         assign bussl_sel_i[s] = bussl_sel_i_flat[4*(s+1)-1:4*s];
         assign bussl_stb_i[s] = bussl_stb_i_flat[s];
         assign bussl_we_i[s] = bussl_we_i_flat[s];
         assign bussl_cab_i[s] = bussl_cab_i_flat[s];
         assign bussl_cti_i[s] = bussl_cti_i_flat[3*(s+1)-1:3*s];
         assign bussl_bte_i[s] = bussl_bte_i_flat[2*(s+1)-1:2*s];
         assign bussl_ack_o_flat[s] = bussl_ack_o[s];
         assign bussl_rty_o_flat[s] = bussl_rty_o[s];
         assign bussl_err_o_flat[s] = bussl_err_o[s];
         assign bussl_dat_o_flat[32*(s+1)-1:32*s] = bussl_dat_o[s];
      end
   endgenerate

   // Set unused interrupts to 0
   assign pic_ints_i[0][31:8] = 24'h0;
   assign pic_ints_i[0][1:0] = 2'b00;
   generate
      for (c = 1; c < CONFIG.CORES_PER_TILE; c = c + 1) begin
         assign pic_ints_i[c] = 32'h0;
      end
   endgenerate

// -----------------------------------------------------------------------------
   // Instantiate the processor cores for the tile
   // Generates wrapper modules and the corresponding mor1kx OpenRISC processors
   // If enabled, also generates debug modules for the cores
   localparam MOR1KX_FEATURE_FPU = (CONFIG.CORE_ENABLE_FPU ? "ENABLED" : "NONE");
   localparam MOR1KX_FEATURE_PERFCOUNTERS = (CONFIG.CORE_ENABLE_PERFCOUNTERS ? "ENABLED" : "NONE");
   localparam MOR1KX_FEATURE_DEBUGUNIT = "NONE"; // XXX: Enable debug unit with OSD CDM module (once it's ready)

   generate
      for (c = 0; c < CONFIG.CORES_PER_TILE; c = c + 1) begin : gen_cores
         mor1kx_module #(
            .ID(c),
            .NUMCORES(CONFIG.CORES_PER_TILE),
            .FEATURE_FPU(MOR1KX_FEATURE_FPU),
            .FEATURE_PERFCOUNTERS(MOR1KX_FEATURE_PERFCOUNTERS),
            .FEATURE_DEBUGUNIT(MOR1KX_FEATURE_DEBUGUNIT))
         u_core(
            // Interfaces
            .trace_exec            (trace[c]),
            // Outputs
            .dbg_lss_o             (),
            .dbg_is_o              (),
            .dbg_wp_o              (),
            .dbg_bp_o              (),
            .dbg_dat_o             (),
            .dbg_ack_o             (),
            .iwb_cyc_o             (busms_cyc_o[c*2]),
            .iwb_adr_o             (busms_adr_o[c*2][31:0]),
            .iwb_stb_o             (busms_stb_o[c*2]),
            .iwb_we_o              (busms_we_o[c*2]),
            .iwb_sel_o             (busms_sel_o[c*2][3:0]),
            .iwb_dat_o             (busms_dat_o[c*2][31:0]),
            .iwb_bte_o             (busms_bte_o[c*2][1:0]),
            .iwb_cti_o             (busms_cti_o[c*2][2:0]),
            .dwb_cyc_o             (busms_cyc_o[c*2+1]),
            .dwb_adr_o             (busms_adr_o[c*2+1][31:0]),
            .dwb_stb_o             (busms_stb_o[c*2+1]),
            .dwb_we_o              (busms_we_o[c*2+1]),
            .dwb_sel_o             (busms_sel_o[c*2+1][3:0]),
            .dwb_dat_o             (busms_dat_o[c*2+1][31:0]),
            .dwb_bte_o             (busms_bte_o[c*2+1][1:0]),
            .dwb_cti_o             (busms_cti_o[c*2+1][2:0]),
            // Inputs
            .clk_i                 (clk_tile),
            .bus_clk_i             (clk_tile),
            .rst_i                 (rst_core),
            .bus_rst_i             (rst_core),
            .dbg_stall_i           (1'b0),
            .dbg_ewt_i             (1'b0),
            .dbg_stb_i             (1'b0),
            .dbg_we_i              (1'b0),
            .dbg_adr_i             (32'h00000000),
            .dbg_dat_i             (32'h00000000),
            .pic_ints_i            (pic_ints_i[c]),
            .iwb_ack_i             (busms_ack_i[c*2]),
            .iwb_err_i             (busms_err_i[c*2]),
            .iwb_rty_i             (busms_rty_i[c*2]),
            .iwb_dat_i             (busms_dat_i[c*2][31:0]),
            .dwb_ack_i             (busms_ack_i[c*2+1]),
            .dwb_err_i             (busms_err_i[c*2+1]),
            .dwb_rty_i             (busms_rty_i[c*2+1]),
            .dwb_dat_i             (busms_dat_i[c*2+1][31:0]),
            .snoop_enable_i        (snoop_enable),
            .snoop_adr_i           (snoop_adr)
         );

         assign busms_cab_o[c*2] = 1'b0;
         assign busms_cab_o[c*2+1] = 1'b0;

         // If enabled, generate OpenSoCDebug Modules for the Cores
         if (CONFIG.USE_DEBUG == 1) begin : gen_ctm_stm
            if (CONFIG.DEBUG_STM == 1) begin : gen_stm
               // OpenSoCDebug Software Trace Module
               // Software can be instrumented to emit trace events (id,value).
               // The STM adds a timestamp to the event.
               osd_stm_mor1kx #(
                  .MAX_PKT_LEN(CONFIG.DEBUG_MAX_PKT_LEN))
               u_stm(
                  .clk  (clk_tile),
                  .rst  (rst_debug),
                  .id   (16'(DEBUG_BASEID + 1 + c*CONFIG.DEBUG_MODS_PER_CORE)),
                  .debug_in (dii_out[1+c*CONFIG.DEBUG_MODS_PER_CORE]),
                  .debug_in_ready (dii_out_ready[1 + c*CONFIG.DEBUG_MODS_PER_CORE]),
                  .debug_out (dii_in[1+c*CONFIG.DEBUG_MODS_PER_CORE]),
                  .debug_out_ready (dii_in_ready[1 + c*CONFIG.DEBUG_MODS_PER_CORE]),
                  .trace_port (trace[c])
               );
            end

            if (CONFIG.DEBUG_CTM == 1) begin : gen_ctm
               // OpenSoCDebug Core Trace Module
               osd_ctm_mor1kx #(
                  .MAX_PKT_LEN(CONFIG.DEBUG_MAX_PKT_LEN))
               u_ctm(
                  .clk  (clk_tile),
                  .rst  (rst_debug),
                  .id   (16'(DEBUG_BASEID + 1 + c*CONFIG.DEBUG_MODS_PER_CORE + (CONFIG.DEBUG_STM == 1 ? 1 : 0))),
                  .debug_in (dii_out[1 + c*CONFIG.DEBUG_MODS_PER_CORE + (CONFIG.DEBUG_STM == 1 ? 1 : 0)]),
                  .debug_in_ready (dii_out_ready[1 + c*CONFIG.DEBUG_MODS_PER_CORE + (CONFIG.DEBUG_STM == 1 ? 1 : 0)]),
                  .debug_out (dii_in[1 + c*CONFIG.DEBUG_MODS_PER_CORE + (CONFIG.DEBUG_STM == 1 ? 1 : 0)]),
                  .debug_out_ready (dii_in_ready[1 + c*CONFIG.DEBUG_MODS_PER_CORE + (CONFIG.DEBUG_STM == 1 ? 1 : 0)]),
                  .trace_port (trace[c])
               );
            end
         end
      end // gen_cores
   endgenerate


// -----------------------------------------------------------------------------
   // OpenSoCDebug: UART Device Emulation Module
   // This module can be connected to a bus and behaves like a standard UART dev.
   generate
      if (CONFIG.USE_DEBUG != 0 && CONFIG.DEBUG_DEM_UART != 0) begin : gen_dem_uart
         osd_dem_uart_wb #()
         u_dem_uart(
            .clk              (clk_tile),
            .rst              (rst_tile),
            .id               (16'(DEBUG_BASEID + CONFIG.DEBUG_MODS_PER_TILE - 1)),
            .irq              (pic_ints_i[0][2]),
            .debug_in         (dii_out[CONFIG.DEBUG_MODS_PER_TILE - 1]),
            .debug_in_ready   (dii_out_ready[CONFIG.DEBUG_MODS_PER_TILE - 1]),
            .debug_out        (dii_in[CONFIG.DEBUG_MODS_PER_TILE - 1]),
            .debug_out_ready  (dii_in_ready[CONFIG.DEBUG_MODS_PER_TILE - 1]),
            .wb_adr_i         (bussl_adr_i[SLAVE_UART][3:0]),
            .wb_cyc_i         (bussl_cyc_i[SLAVE_UART]),
            .wb_dat_i         (bussl_dat_i[SLAVE_UART]),
            .wb_sel_i         (bussl_sel_i[SLAVE_UART]),
            .wb_stb_i         (bussl_stb_i[SLAVE_UART]),
            .wb_we_i          (bussl_we_i[SLAVE_UART]),
            .wb_cti_i         (bussl_cti_i[SLAVE_UART]),
            .wb_bte_i         (bussl_bte_i[SLAVE_UART]),
            .wb_ack_o         (bussl_ack_o[SLAVE_UART]),
            .wb_err_o         (bussl_err_o[SLAVE_UART]),
            .wb_rty_o         (bussl_rty_o[SLAVE_UART]),
            .wb_dat_o         (bussl_dat_o[SLAVE_UART])
         );
      end
   endgenerate


   // -----------------------------------------------------------------------------
   // Surveillance Module
   generate
      if (CONFIG.USE_DEBUG != 0 && CONFIG.DEBUG_SM != 0) begin : gen_sm
         surveillance_module #(
            .MAX_LEN          (MAX_BE_PKT_LEN > TDM_MAX_CHECKPOINT_DIST ? MAX_BE_PKT_LEN : TDM_MAX_CHECKPOINT_DIST),
            .NUM_TDM_ENDPOINTS(TDM_CHANNELS),
            .NUM_TILES        (CONFIG.NUMTILES),
            .MAX_DI_PKT_LEN   (CONFIG.DEBUG_MAX_PKT_LEN),
            .ID(ID))
         u_surveillance_module(
            .clk              (clk_tile),
            .rst_dbg          (rst_debug),
            .rst_sys          (rst_tile),

            // wires between wb and na
            .wb_na_addr       (bussl_adr_i[SLAVE_NA]),
            .wb_na_data_in    (bussl_dat_i[SLAVE_NA]),  // sent data
            .wb_na_data_out   (bussl_dat_o[SLAVE_NA]), // received data
            .wb_na_we         (bussl_we_i[SLAVE_NA]),
            .wb_na_cyc        (bussl_cyc_i[SLAVE_NA]),
            .wb_na_stb        (bussl_stb_i[SLAVE_NA]),
            .wb_na_ack        (bussl_ack_o[SLAVE_NA]),

            // debug i/o
            // if UART is enabled this is the second to last debug module,
            // else last module
            .debug_in         (dii_out[CONFIG.DEBUG_MODS_PER_TILE - 1 - (CONFIG.DEBUG_DEM_UART == 1 ? 1 : 0)]),
            .debug_in_ready   (dii_out_ready[CONFIG.DEBUG_MODS_PER_TILE - 1 - (CONFIG.DEBUG_DEM_UART == 1 ? 1 : 0)]),
            .debug_out        (dii_in[CONFIG.DEBUG_MODS_PER_TILE - 1 - (CONFIG.DEBUG_DEM_UART == 1 ? 1 : 0)]),
            .debug_out_ready  (dii_in_ready[CONFIG.DEBUG_MODS_PER_TILE - 1 - (CONFIG.DEBUG_DEM_UART == 1 ? 1 : 0)]),

            // ports to wb
            .wb_addr            (bussl_adr_i[SLAVE_SM]),
            .wb_cyc             (bussl_cyc_i[SLAVE_SM]),
            .wb_data_in         (bussl_dat_i[SLAVE_SM]),
            .wb_sel             (bussl_sel_i[SLAVE_SM]),
            .wb_stb             (bussl_stb_i[SLAVE_SM]),
            .wb_we              (bussl_we_i[SLAVE_SM]),
            .wb_cab             (bussl_cab_i[SLAVE_SM]),
            .wb_cti             (bussl_cti_i[SLAVE_SM]),
            .wb_bte             (bussl_bte_i[SLAVE_SM]),
            .wb_ack             (bussl_ack_o[SLAVE_SM]),
            .wb_rty             (bussl_rty_o[SLAVE_SM]),
            .wb_err             (bussl_err_o[SLAVE_SM]),
            .wb_data_out        (bussl_dat_o[SLAVE_SM]),

            .irq  (pic_ints_i[0][7]),
            .id   (16'(DEBUG_BASEID + CONFIG.DEBUG_MODS_PER_TILE - 1 - (CONFIG.DEBUG_DEM_UART == 1 ? 1 : 0)))
         );
      end else begin // if
         // Set Bus Slave Outputs to zero
         assign bussl_dat_o[SLAVE_SM] = 32'h0;
         assign bussl_ack_o[SLAVE_SM] = 1'b0;
         assign bussl_err_o[SLAVE_SM] = 1'b0;
         assign bussl_rty_o[SLAVE_SM] = 1'b0;
      end // else
   endgenerate



// -----------------------------------------------------------------------------
   // Generic Wishbone Bus B3, instantiated with 6 Slaves.
   // The ports are flatted, all masters share the bus signal ports.
   // The memory map is defined with the S?_RANGE_WIDTH and S?_RANGE_MATCH parameters.

   wb_bus_b3 #(
      .MASTERS(NR_MASTERS),.SLAVES(NR_SLAVES),
      .S0_ENABLE(CONFIG.ENABLE_DM),
      .S0_RANGE_WIDTH(CONFIG.DM_RANGE_WIDTH),.S0_RANGE_MATCH(CONFIG.DM_RANGE_MATCH),
      .S1_ENABLE(CONFIG.ENABLE_PGAS),
      .S1_RANGE_WIDTH(CONFIG.PGAS_RANGE_WIDTH),.S1_RANGE_MATCH(CONFIG.PGAS_RANGE_MATCH),
      .S2_RANGE_WIDTH(4),.S2_RANGE_MATCH(4'he),
      .S3_ENABLE(CONFIG.ENABLE_BOOTROM),
      .S3_RANGE_WIDTH(4),.S3_RANGE_MATCH(4'hf),
      .S4_ENABLE(CONFIG.DEBUG_DEM_UART),
      .S4_RANGE_WIDTH(28),.S4_RANGE_MATCH(28'h9000000),
      .S5_ENABLE(CONFIG.DEBUG_SM),
      .S5_RANGE_WIDTH(16),.S5_RANGE_MATCH(16'ha000))
   u_bus(
      .clk_i                         (clk_tile),
      .rst_i                         (rst_tile),
      // Outputs
      .m_dat_o                       (busms_dat_i_flat),
      .m_ack_o                       (busms_ack_i_flat),
      .m_err_o                       (busms_err_i_flat),
      .m_rty_o                       (busms_rty_i_flat),
      .s_adr_o                       (bussl_adr_i_flat),
      .s_dat_o                       (bussl_dat_i_flat),
      .s_cyc_o                       (bussl_cyc_i_flat),
      .s_stb_o                       (bussl_stb_i_flat),
      .s_sel_o                       (bussl_sel_i_flat),
      .s_we_o                        (bussl_we_i_flat),
      .s_cti_o                       (bussl_cti_i_flat),
      .s_bte_o                       (bussl_bte_i_flat),
      .snoop_adr_o                   (snoop_adr),
      .snoop_en_o                    (snoop_enable),
      .bus_hold_ack                  (),
      // Inputs
      .m_adr_i                       (busms_adr_o_flat),
      .m_dat_i                       (busms_dat_o_flat),
      .m_cyc_i                       (busms_cyc_o_flat),
      .m_stb_i                       (busms_stb_o_flat),
      .m_sel_i                       (busms_sel_o_flat),
      .m_we_i                        (busms_we_o_flat),
      .m_cti_i                       (busms_cti_o_flat),
      .m_bte_i                       (busms_bte_o_flat),
      .s_dat_i                       (bussl_dat_o_flat),
      .s_ack_i                       (bussl_ack_o_flat),
      .s_err_i                       (bussl_err_o_flat),
      .s_rty_i                       (bussl_rty_o_flat),
      .bus_hold                      (1'b0)
   );
   // Unused leftover from an older Wishbone spec version
   assign bussl_cab_i_flat = NR_SLAVES'(1'b0);


// -----------------------------------------------------------------------------
  // OpenSoCDebug: Memory Access Module
   if (CONFIG.USE_DEBUG == 1) begin : gen_mam_dm_wb
      osd_mam_wb #(
         .DATA_WIDTH(32),
         .MAX_PKT_LEN(CONFIG.DEBUG_MAX_PKT_LEN),
         .MEM_SIZE0(CONFIG.LMEM_SIZE),
         .BASE_ADDR0(0))
      u_mam_dm_wb(
         .clk_i(clk_tile),
         .rst_i(rst_debug),
         .debug_in(dii_out[0]),
         .debug_in_ready(dii_out_ready[0]),
         .debug_out(dii_in[0]),
         .debug_out_ready(dii_in_ready[0]),
         .id (16'(DEBUG_BASEID)),
         .stb_o(mam_dm_stb_o),
         .cyc_o(mam_dm_cyc_o),
         .ack_i(mam_dm_ack_i),
         .we_o(mam_dm_we_o),
         .addr_o(mam_dm_addr_o),
         .dat_o(mam_dm_dat_o),
         .dat_i(mam_dm_dat_i),
         .cti_o(mam_dm_cti_o),
         .bte_o(mam_dm_bte_o),
         .sel_o(mam_dm_sel_o)
      );
   end //if (USE_DEBUG == 1)

   // If enabled, generate the Wishbone Adapter for the Memory Access Module
   if (CONFIG.ENABLE_DM) begin : gen_mam_wb_adapter
      mam_wb_adapter #(
         .DW(32),
         .AW(32))
      u_mam_wb_adapter_dm(
         .wb_mam_adr_o    (mam_dm_addr_o),
         .wb_mam_cyc_o    (mam_dm_cyc_o),
         .wb_mam_dat_o    (mam_dm_dat_o),
         .wb_mam_sel_o    (mam_dm_sel_o),
         .wb_mam_stb_o    (mam_dm_stb_o),
         .wb_mam_we_o     (mam_dm_we_o),
         .wb_mam_cab_o    (1'b0),
         .wb_mam_cti_o    (mam_dm_cti_o),
         .wb_mam_bte_o    (mam_dm_bte_o),
         .wb_mam_ack_i    (mam_dm_ack_i),
         .wb_mam_rty_i    (mam_dm_rty_i),
         .wb_mam_err_i    (mam_dm_err_i),
         .wb_mam_dat_i    (mam_dm_dat_i),

         // Outputs
         .wb_in_ack_o     (bussl_ack_o[SLAVE_DM]),
         .wb_in_err_o     (bussl_err_o[SLAVE_DM]),
         .wb_in_rty_o     (bussl_rty_o[SLAVE_DM]),
         .wb_in_dat_o     (bussl_dat_o[SLAVE_DM]),
         .wb_out_adr_i    (wb_mem_adr_i),
         .wb_out_bte_i    (wb_mem_bte_i),
         .wb_out_cti_i    (wb_mem_cti_i),
         .wb_out_cyc_i    (wb_mem_cyc_i),
         .wb_out_dat_i    (wb_mem_dat_i),
         .wb_out_sel_i    (wb_mem_sel_i),
         .wb_out_stb_i    (wb_mem_stb_i),
         .wb_out_we_i     (wb_mem_we_i),
         .wb_out_clk_i    (wb_mem_clk_i),
         .wb_out_rst_i    (wb_mem_rst_i),
         // Inputs
         .wb_in_adr_i     (bussl_adr_i[SLAVE_DM]),
         .wb_in_bte_i     (bussl_bte_i[SLAVE_DM]),
         .wb_in_cti_i     (bussl_cti_i[SLAVE_DM]),
         .wb_in_cyc_i     (bussl_cyc_i[SLAVE_DM]),
         .wb_in_dat_i     (bussl_dat_i[SLAVE_DM]),
         .wb_in_sel_i     (bussl_sel_i[SLAVE_DM]),
         .wb_in_stb_i     (bussl_stb_i[SLAVE_DM]),
         .wb_in_we_i      (bussl_we_i[SLAVE_DM]),
         .wb_in_clk_i     (clk_tile),
         .wb_in_rst_i     (rst_tile),
         .wb_out_ack_o    (wb_mem_ack_o),
         .wb_out_err_o    (wb_mem_err_o),
         .wb_out_rty_o    (wb_mem_rty_o),
         .wb_out_dat_o    (wb_mem_dat_o)
      );
   end else begin // if (CONFIG.ENABLE_DM)
     // If not enabled, wire bus outputs to zero
      assign mam_dm_dat_i = 32'hx;
      assign {mam_dm_ack_i, mam_dm_err_i, mam_dm_rty_i} = 3'b000;
      assign bussl_dat_o[SLAVE_DM] = 32'hx;
      assign bussl_ack_o[SLAVE_DM] = 1'b0;
      assign bussl_err_o[SLAVE_DM] = 1'b0;
      assign bussl_rty_o[SLAVE_DM] = 1'b0;
   end

// -----------------------------------------------------------------------------
   // Generic SRAM implementation plus the corresponding Wishbone Interface
   generate
      if ((CONFIG.ENABLE_DM) && (CONFIG.LMEM_STYLE == PLAIN)) begin : gen_sram
         wb_sram_sp #(
            .DW(32),
            .AW(clog2_width(CONFIG.LMEM_SIZE)),
            .MEM_SIZE_BYTE(CONFIG.LMEM_SIZE),
            .MEM_FILE(MEM_FILE),
            .MEM_IMPL_TYPE("PLAIN"))
         u_ram(
            // Outputs
            .wb_ack_o    (wb_mem_ack_o),
            .wb_err_o    (wb_mem_err_o),
            .wb_rty_o    (wb_mem_rty_o),
            .wb_dat_o    (wb_mem_dat_o),
            // Inputs
            .wb_adr_i    (wb_mem_adr_i[clog2_width(CONFIG.LMEM_SIZE)-1:0]),
            .wb_bte_i    (wb_mem_bte_i),
            .wb_cti_i    (wb_mem_cti_i),
            .wb_cyc_i    (wb_mem_cyc_i),
            .wb_dat_i    (wb_mem_dat_i),
            .wb_sel_i    (wb_mem_sel_i),
            .wb_stb_i    (wb_mem_stb_i),
            .wb_we_i     (wb_mem_we_i),
            .wb_clk_i    (wb_mem_clk_i),
            .wb_rst_i    (wb_mem_rst_i)
         );
      end else begin // block: gen_sram
         // If memory style is not plain or direct memory access is not enabled,
         // wire external Wishbone Bus as memory bus interface.
         assign wb_ext_adr_i = wb_mem_adr_i;
         assign wb_ext_bte_i = wb_mem_bte_i;
         assign wb_ext_cti_i = wb_mem_cti_i;
         assign wb_ext_cyc_i = wb_mem_cyc_i;
         assign wb_ext_dat_i = wb_mem_dat_i;
         assign wb_ext_sel_i = wb_mem_sel_i;
         assign wb_ext_stb_i = wb_mem_stb_i;
         assign wb_ext_we_i = wb_mem_we_i;
         assign wb_mem_ack_o = wb_ext_ack_o;
         assign wb_mem_rty_o = wb_ext_rty_o;
         assign wb_mem_err_o = wb_ext_err_o;
         assign wb_mem_dat_o = wb_ext_dat_o;
      end // else: !if((CONFIG.ENABLE_DM) &&...
   endgenerate

// -----------------------------------------------------------------------------
   // PGAS Slave is currently unused
   if (!CONFIG.ENABLE_PGAS) begin : gen_tieoff_pgas
      assign bussl_dat_o[SLAVE_PGAS] = 32'h0;
      assign bussl_ack_o[SLAVE_PGAS] = 1'b0;
      assign bussl_err_o[SLAVE_PGAS] = 1'b0;
      assign bussl_rty_o[SLAVE_PGAS] = 1'b0;
   end



// -----------------------------------------------------------------------------
  // BOOTROM
  // Simple ROM used at boot time.
   generate
      if (CONFIG.ENABLE_BOOTROM) begin : gen_bootrom
         bootrom #()
         u_bootrom(
            .clk        (clk_tile),
            .rst        (rst_tile),
            // Outputs
            .wb_dat_o   (bussl_dat_o[SLAVE_BOOT]),
            .wb_ack_o   (bussl_ack_o[SLAVE_BOOT]),
            .wb_err_o   (bussl_err_o[SLAVE_BOOT]),
            .wb_rty_o   (bussl_rty_o[SLAVE_BOOT]),
            // Inputs
            .wb_adr_i   (bussl_adr_i[SLAVE_BOOT]),
            .wb_dat_i   (bussl_dat_i[SLAVE_BOOT]),
            .wb_cyc_i   (bussl_cyc_i[SLAVE_BOOT]),
            .wb_stb_i   (bussl_stb_i[SLAVE_BOOT]),
            .wb_sel_i   (bussl_sel_i[SLAVE_BOOT])
         );
      end else begin // if (CONFIG.ENABLE_BOOTROM)
         // Set Bus Slave Outputs to zero
         assign bussl_dat_o[SLAVE_BOOT] = 32'hx;
         assign bussl_ack_o[SLAVE_BOOT] = 1'b0;
         assign bussl_err_o[SLAVE_BOOT] = 1'b0;
         assign bussl_rty_o[SLAVE_BOOT] = 1'b0;
      end // else: !if(CONFIG.ENABLE_BOOTROM)
   endgenerate



   // -----------------------------------------------------------------------------
   // Network Interface for the Hybric TDM NoC
   // This Network Interface supports TDM, as well as Best Effort(BE) Traffic.
   // Its BE part is compatible with the original OptimSoC Network Adapter.
   hybrid_noc_ni #(
      .CONFIG                    (CONFIG),
      .TILEID                    (ID),
      .COREBASE                  (COREBASE),
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
      .clk_bus            (clk_tile),
      .clk_noc            (clk_noc),
      .rst_bus            (rst_tile),
      .rst_noc            (rst_noc),

      .in_flit            (noc_in_flit),
      .in_last            (noc_in_last),
      .tdm_in_valid       (noc_tdm_in_valid),
      .be_in_valid        (noc_be_in_valid),
      .be_in_ready        (noc_be_in_ready),
      .link_error         (link_error),

      .out_flit           (noc_out_flit),
      .out_last           (noc_out_last),
      .tdm_out_valid      (noc_tdm_out_valid),
      .be_out_valid       (noc_be_out_valid),
      .be_out_ready       (noc_be_out_ready),

      .wb_addr            (bussl_adr_i[SLAVE_NA]),
      .wb_cyc             (bussl_cyc_i[SLAVE_NA]),
      .wb_data_in         (bussl_dat_i[SLAVE_NA]),
      .wb_sel             (bussl_sel_i[SLAVE_NA]),
      .wb_stb             (bussl_stb_i[SLAVE_NA]),
      .wb_we              (bussl_we_i[SLAVE_NA]),
      .wb_cab             (bussl_cab_i[SLAVE_NA]),
      .wb_cti             (bussl_cti_i[SLAVE_NA]),
      .wb_bte             (bussl_bte_i[SLAVE_NA]),
      .wb_ack             (bussl_ack_o[SLAVE_NA]),
      .wb_rty             (bussl_rty_o[SLAVE_NA]),
      .wb_err             (bussl_err_o[SLAVE_NA]),
      .wb_data_out        (bussl_dat_o[SLAVE_NA]),

      .irq                (pic_ints_i[0][6:3]),

      .lut_conf_data      (lut_conf_data),
      .lut_conf_sel       (lut_conf_sel),
      .lut_conf_slot      (lut_conf_slot),
      .lut_conf_valid     (lut_conf_valid),
      .link_en_valid      (link_en_valid)
  );
endmodule //compute_tile_dm
