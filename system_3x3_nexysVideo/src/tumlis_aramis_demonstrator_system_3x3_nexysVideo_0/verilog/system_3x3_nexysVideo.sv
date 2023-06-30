/* Copyright (c) 2023 by the author(s)
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
 * Toplevel for the 3x3 distributed memory system for the ARAMiS II demonstrator
 * on a NexysVideo board.
 *
 * Parameters:
 *   NUM_LCT_CORES:
 *     Number of CPU cores inside each low critical compute tile (default: 1)
 *
 *   NUM_HCT_CORES:
 *     Number of CPU cores inside each critical compute tile (default: 1)
 *
 *   LCT_LMEM_SIZE:
 *     Size of the local distributed memory in low critical tiles in bytes
 *     (default: 32 MB)
 *
 *   HCT_LMEM_SIZE:
 *     Size of the local distributed memory in critical tiles in bytes
 *     (default: 1 MB)
 *
 *   LCT_LMEM_STYLE:
 *     Style of the local distributed memory in low critical tiles. 'plain' for
 *     SRAM and 'external' for the external DRAM (default: 'external')
 *
 *   HCT_LMEM_STYLE:
 *     Style of the local distributed memory in critical tiles. 'plain' for
 *     SRAM and 'external' for the external DRAM (default: 'external')
 *
 *   HOST_IF:
 *     Off-chip host interface (default: "usb3")
 *
 *   UART0_SOURCE:
 *     Source of the UART connection (default: "pmod")
 *
 *   LUT_SIZE:
 *     Size of the slot tables (default: 8)
 *
 *   MAX_BE_PKT_LEN:
 *     Maximum number of flits for BE packets (default: 8)
 *
 *   TDM_MAX_CHECKPOINT_DIST:
 *     Maximum number of flits between two checkpoints for TDM traffic
 *     (default: 8)
 *
 *   ENABLE_DR:
 *     Use distributed routing for packet switched BE traffic instead of source
 *     routing (default: 0)
 *
 *   SIMPLE_NCM:
 *     Use simplified version of the NoC control module (only for slot table
 *     configuration) (default: 0)
 *
 *   ENABLE_FDM_NI:
 *     Enable the fault detection and parity encoder modules in the NIs
 *     (default: 1)
 *
 *   ENABLE_FDM_FIM_NOC:
 *     Enable the fault detection and injection modules in the NoC. Only enable
 *     if ENABLE_FDM_NI is enabled too. (default: 1)
 *
 *   NUM_BE_ENDPOINTS:
 *     Number of BE endpoints in each NI (default: 1)
 *
 *
 * The tile mapping is as follows (I/O tile to be added, currently another LCT):
 *
 *       x_dir ->
 * y_dir
 *   |   LCT - HCT - HCT
 *   v    |     |     |
 *       I/O - LCT - LCT
 *        |     |     |
 *       LCT - HCT - LCT
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module system_3x3_nexysVideo
   import dii_package::dii_flit;
   import optimsoc_config::*;
#(
   parameter integer NUM_LCT_CORES = 1,
   parameter integer NUM_HCT_CORES = 1,
   parameter integer LCT_LMEM_SIZE = 1*1024*1024,
   parameter integer HCT_LMEM_SIZE = 1*1024*1024,//768*1024,
   parameter LCT_LMEM_STYLE = "external",
   parameter HCT_LMEM_STYLE = "external",//"plain",
   // Off-chip host interface
   // uart: use a UART connection (see UART0_SOURCE for connectivity options)
   // usb3: use a USB 3 connection (through a Cypress FX3 chip)
   parameter HOST_IF = "uart",
   // Source of the UART connection
   // onboard: Use the UART chip on the NexysVideo board
   // pmod: Connect a pmodusbuart module to JB (bottom row)
   parameter UART_SOURCE = "pmod",
   parameter integer LUT_SIZE = 8,
   parameter integer MAX_BE_PKT_LEN = 8,
   parameter integer TDM_MAX_CHECKPOINT_DIST = 8,
   parameter ENABLE_DR = 1,
   parameter SIMPLE_NCM = 0,
   parameter ENABLE_FDM_NI = 1,
   parameter ENABLE_FDM_FIM_NOC = 1,
   parameter NUM_BE_ENDPOINTS = 1,
   parameter NUM_TDM_EP_LPT = 1,
   parameter NUM_TDM_EP_HPT = 1,
   parameter NUM_TDM_EP_IO = 3,
   localparam CT_LINKS = 2,
   // 3 MBaud, max. for FT232R
   localparam UART0_BAUD = 3000000
)(
   // 100 MHz system clock from board
   input             clk,
   // Button "CPU RESET" (G4)
   input             cpu_rst_n,

   // Important note:
   // All UART names are from FPGA point of view.
   // onboard UART; no RTS and CTS available
   output            usb_uart_tx,
   input             usb_uart_rx,

   // UART over PMOD (bottom row of JB)
   output            pmod_uart_tx,
   input             pmod_uart_rx,
   output            pmod_uart_rts, // active low (despite the name)
   input             pmod_uart_cts, // active low (despite the name)

   // DDR
   inout [15:0]      ddr3_dq,
   inout [1:0]       ddr3_dqs_n,
   inout [1:0]       ddr3_dqs_p,
   output [14:0]     ddr3_addr,
   output [2:0]      ddr3_ba,
   output            ddr3_ras_n,
   output            ddr3_cas_n,
   output            ddr3_we_n,
   output            ddr3_reset_n,
   output [0:0]      ddr3_ck_p,
   output [0:0]      ddr3_ck_n,
   output [0:0]      ddr3_cke,
   output [1:0]      ddr3_dm,
   output [0:0]      ddr3_odt,

   // Cypress FX3 connected to FMC
   output            fx3_pclk,
   inout [15:0]      fx3_dq,
   output            fx3_slcs_n,
   output            fx3_sloe_n,
   output            fx3_slrd_n,
   output            fx3_slwr_n,
   output            fx3_pktend_n,
   output [1:0]      fx3_a,
   input             fx3_flaga_n,
   input             fx3_flagb_n,
   input             fx3_flagc_n,
   input             fx3_flagd_n,
   input             fx3_com_rst,
   input             fx3_logic_rst,
   output [2:0]      fx3_pmode
);

   localparam AXI_ID_WIDTH = 4;
   localparam DDR_ADDR_WIDTH = 29;
   localparam DDR_DATA_WIDTH = 32;
   localparam TILE_ADDR_WIDTH = DDR_ADDR_WIDTH - 4;
   localparam TILES = 9;

   // This struct defines the global configuration as well as the configuration
   // of the LCTs.
   localparam base_config_t
      BASE_CONFIG_LCT = '{
         NUMTILES: 9,
         NUMCTS: 8,
         CTLIST: {{56{16'hx}}, 16'h0, 16'h1, 16'h2, 16'h4, 16'h5, 16'h6, 16'h7, 16'h8},
         CORES_PER_TILE: NUM_LCT_CORES,
         GMEM_SIZE: 0,
         GMEM_TILE: 'x,
         NOC_ENABLE_VCHANNELS: 0,
         LMEM_SIZE: LCT_LMEM_SIZE,
         LMEM_STYLE: LCT_LMEM_STYLE == "external" ? EXTERNAL : PLAIN,
         ENABLE_BOOTROM: 0,
         BOOTROM_SIZE: 0,
         ENABLE_DM: 1,
         DM_BASE: 32'h0,
         DM_SIZE: LCT_LMEM_SIZE,
         ENABLE_PGAS: 0,
         PGAS_BASE: 0,
         PGAS_SIZE: 0,
         CORE_ENABLE_FPU: 0,
         CORE_ENABLE_PERFCOUNTERS: 0,
         NA_ENABLE_MPSIMPLE: 1,
         NA_ENABLE_DMA: 0,
         NA_DMA_GENIRQ: 1,
         NA_DMA_ENTRIES: 4,
         USE_DEBUG: 1,
         DEBUG_STM: 1,
         DEBUG_CTM: 0,
         DEBUG_DEM_UART: 0,
         DEBUG_SM: 1,
         DEBUG_SUBNET_BITS: 6,
         DEBUG_LOCAL_SUBNET: 0,
         DEBUG_ROUTER_BUFFER_SIZE: 4,
         DEBUG_MAX_PKT_LEN: 12
      };
   // This struct defines the configuration of the HCTs. Currently only the
   // number of cores per tile differs.
   localparam base_config_t
      BASE_CONFIG_HCT = '{
         NUMTILES: 9,
         NUMCTS: 8,
         CTLIST: {{56{16'hx}}, 16'h0, 16'h1, 16'h2, 16'h4, 16'h5, 16'h6, 16'h7, 16'h8},
         CORES_PER_TILE: NUM_HCT_CORES,
         GMEM_SIZE: 0,
         GMEM_TILE: 'x,
         NOC_ENABLE_VCHANNELS: 0,
         LMEM_SIZE: HCT_LMEM_SIZE,
         LMEM_STYLE: HCT_LMEM_STYLE == "external" ? EXTERNAL : PLAIN,
         ENABLE_BOOTROM: 0,
         BOOTROM_SIZE: 0,
         ENABLE_DM: 1,
         DM_BASE: 32'h0,
         DM_SIZE: HCT_LMEM_SIZE,
         ENABLE_PGAS: 0,
         PGAS_BASE: 0,
         PGAS_SIZE: 0,
         CORE_ENABLE_FPU: 0,
         CORE_ENABLE_PERFCOUNTERS: 0,
         NA_ENABLE_MPSIMPLE: 1,
         NA_ENABLE_DMA: 0,
         NA_DMA_GENIRQ: 1,
         NA_DMA_ENTRIES: 4,
         USE_DEBUG: 1,
         DEBUG_STM: 1,
         DEBUG_CTM: 0,
         DEBUG_DEM_UART: 0,
         DEBUG_SM: 1,
         DEBUG_SUBNET_BITS: 6,
         DEBUG_LOCAL_SUBNET: 0,
         DEBUG_ROUTER_BUFFER_SIZE: 4,
         DEBUG_MAX_PKT_LEN: 12
      };

   localparam config_t CONFIG_LCT = derive_config(BASE_CONFIG_LCT);
   localparam config_t CONFIG_HCT = derive_config(BASE_CONFIG_HCT);

   // Array defining the type of each tile. This defines the tile mapping
   // described above.
   // Type '0' = LCT, Type '1' = HTC, Type '2' = I/O
   localparam [TILES-1:0][3:0] TILE_TYPE = {4'h0, 4'h1, 4'h0, 4'h0, 4'h0, 4'h2, 4'h1, 4'h1, 4'h0};

   nasti_channel #(
      .ID_WIDTH   (0),
      .ADDR_WIDTH (TILE_ADDR_WIDTH),
      .DATA_WIDTH (DDR_DATA_WIDTH))
   c_axi_tile[TILES-1:0](),
   c_axi_ddr[TILES-1:0]();

   nasti_channel #(
      .ID_WIDTH   (AXI_ID_WIDTH),
      .ADDR_WIDTH (DDR_ADDR_WIDTH),
      .DATA_WIDTH (DDR_DATA_WIDTH))
   c_axi_ddr_board();

   wb_channel #(
      .ADDR_WIDTH (32),
      .DATA_WIDTH (DDR_DATA_WIDTH))
   c_wb_ddr[TILES-1:0]();

   wire [TILES-1:0][31:0]  wb_ext_adr_i;
   wire [TILES-1:0][0:0]   wb_ext_cyc_i;
   wire [TILES-1:0][31:0]  wb_ext_dat_i;
   wire [TILES-1:0][3:0]   wb_ext_sel_i;
   wire [TILES-1:0][0:0]   wb_ext_stb_i;
   wire [TILES-1:0][0:0]   wb_ext_we_i;
   wire [TILES-1:0][2:0]   wb_ext_cti_i;
   wire [TILES-1:0][1:0]   wb_ext_bte_i;
   wire [TILES-1:0][0:0]   wb_ext_ack_o;
   wire [TILES-1:0][0:0]   wb_ext_rty_o;
   wire [TILES-1:0][0:0]   wb_ext_err_o;
   wire [TILES-1:0][31:0]  wb_ext_dat_o;

   genvar i;
   generate
      for (i = 0; i < TILES; i++) begin
         assign wb_ext_adr_i[i] = c_wb_ddr[i].adr_o;
         assign wb_ext_cyc_i[i] = c_wb_ddr[i].cyc_o;
         assign wb_ext_dat_i[i] = c_wb_ddr[i].dat_o;
         assign wb_ext_sel_i[i] = c_wb_ddr[i].sel_o;
         assign wb_ext_stb_i[i] = c_wb_ddr[i].stb_o;
         assign wb_ext_we_i[i] = c_wb_ddr[i].we_o;
         assign wb_ext_cti_i[i] = c_wb_ddr[i].cti_o;
         assign wb_ext_bte_i[i] = c_wb_ddr[i].bte_o;
         assign c_wb_ddr[i].ack_i = wb_ext_ack_o[i];
         assign c_wb_ddr[i].rty_i = wb_ext_rty_o[i];
         assign c_wb_ddr[i].err_i = wb_ext_err_o[i];
         assign c_wb_ddr[i].dat_i = wb_ext_dat_o[i];
      end
   endgenerate

   // Clocks and reset
   // cpu_reset_n is a push button on the board labeled "CPU RESET"
   wire glip_com_rst, glip_ctrl_logic_rst;

   // System clock: 100 MHz
   wire sys_clk_100;
   // System clock: 50 MHz
   wire sys_clk_50;

   // Define clock domains
   wire clk_noc;
   wire clk_debug;
   wire clk_lct;
   wire clk_hct;

   // The clock of each tile accessing the DDR must be set to 50MHz to match the
   // setting in the NexysVideo board wrapper for DDR access.
   assign clk_noc = sys_clk_100;
   assign clk_debug = sys_clk_50;
   assign clk_lct = sys_clk_50;
   assign clk_hct = sys_clk_50;

   // Reset from the board and the memory subsystem. Held low until the MIG is
   // ready.
   wire sys_rst_board;

   // System reset: triggered either from the board, or from the user through
   // GLIP's glip_logic_reset() function
   // XXX: Currently the reset logic of HIM does not take the glip_com_rst
   // properly into account in order to support "hot attach", i.e. connecting
   // to a already running system without fully resetting it. Until this is
   // properly being worked out, we take the glip_com_reset also as system
   // reset to reset the full system (i.e. all CPUs and the debug system).
   wire sys_rst;
   assign sys_rst = sys_rst_board | glip_ctrl_logic_rst | glip_com_rst;

   // Internal UART signals (naming from FPGA point of view)
   // CTS & RTS signals are currently ignored, even if pmod UART is used
   wire uart_rx, uart_tx;
   assign pmod_uart_rts = 1'b0;

   // Debug system
   glip_channel c_glip_in(.clk(clk_debug));
   glip_channel c_glip_out(.clk(clk_debug));

   // Host (off-chip) interface through GLIP (mostly for debug)
   generate
      if (HOST_IF == "uart") begin
         if (UART_SOURCE == "onboard") begin
            assign usb_uart_tx = uart_tx;
            assign uart_rx = usb_uart_rx;
         end else if (UART_SOURCE == "pmod") begin
            assign pmod_uart_tx = uart_tx;
            assign uart_rx = pmod_uart_rx;
         end
         glip_uart_toplevel #(
            .FREQ_CLK_IO(32'd50_000_000),
            .BAUD(UART0_BAUD),
            .WIDTH(16),
            .BUFFER_OUT_DEPTH(256*1024))
         u_glip(
            .clk_io           (sys_clk_50),
            .clk              (clk_debug),
            .rst              (sys_rst_board),
            .com_rst          (glip_com_rst),
            .ctrl_logic_rst   (glip_ctrl_logic_rst),

            .error(/* XXX: connect this to a LED */),

            .fifo_out_data    (c_glip_out.data),
            .fifo_out_ready   (c_glip_out.ready),
            .fifo_out_valid   (c_glip_out.valid),
            .fifo_in_data     (c_glip_in.data),
            .fifo_in_ready    (c_glip_in.ready),
            .fifo_in_valid    (c_glip_in.valid),

            .uart_rx          (uart_rx),
            .uart_tx          (uart_tx),
            .uart_rts_n       (),
            .uart_cts_n       (0)
         );
      end else if (HOST_IF == "usb3") begin
         glip_cypressfx3_toplevel #(
            .WIDTH(16))
         u_glip(
            .clk              (clk_debug),
            .clk_io_100       (sys_clk_100),
            .rst              (sys_rst_board),
            .com_rst          (glip_com_rst),
            .ctrl_logic_rst   (glip_ctrl_logic_rst),

            .fifo_out_data    (c_glip_out.data),
            .fifo_out_ready   (c_glip_out.ready),
            .fifo_out_valid   (c_glip_out.valid),
            .fifo_in_data     (c_glip_in.data),
            .fifo_in_ready    (c_glip_in.ready),
            .fifo_in_valid    (c_glip_in.valid),

            .fx3_pclk         (fx3_pclk),
            .fx3_dq           (fx3_dq),
            .fx3_slcs_n       (fx3_slcs_n),
            .fx3_sloe_n       (fx3_sloe_n),
            .fx3_slrd_n       (fx3_slrd_n),
            .fx3_slwr_n       (fx3_slwr_n),
            .fx3_pktend_n     (fx3_pktend_n),
            .fx3_a            (fx3_a[1:0]),
            .fx3_flaga_n      (fx3_flaga_n),
            .fx3_flagb_n      (fx3_flagb_n),
            .fx3_flagc_n      (fx3_flagc_n),
            .fx3_flagd_n      (fx3_flagd_n),
            .fx3_com_rst      (fx3_com_rst),
            .fx3_logic_rst    (fx3_logic_rst),
            .fx3_pmode        (fx3_pmode)
         );
      end
   endgenerate

   // 3x3 distributed memory system with all memory mapped to DDR
   system_3x3 #(
      .CONFIG_LPT(CONFIG_LCT),
      .CONFIG_HPT(CONFIG_HCT),
      .TILE_TYPE(TILE_TYPE),
      .LUT_SIZE(LUT_SIZE),
      .CT_LINKS(CT_LINKS),
      .MAX_BE_PKT_LEN(MAX_BE_PKT_LEN),
      .NUM_BE_ENDPOINTS(NUM_BE_ENDPOINTS),
      .TDM_MAX_CHECKPOINT_DIST(TDM_MAX_CHECKPOINT_DIST),
      .CDC_LPT(1),
      .CDC_HPT(1),
      .ENABLE_DR(ENABLE_DR),
      .SIMPLE_NCM(SIMPLE_NCM),
      .ENABLE_FDM_NI(ENABLE_FDM_NI),
      .ENABLE_FDM_FIM_NOC(ENABLE_FDM_FIM_NOC),
      .NUM_TDM_EP_LPT(NUM_TDM_EP_LPT),
      .NUM_TDM_EP_HPT(NUM_TDM_EP_HPT),
      .NUM_TDM_EP_IO(NUM_TDM_EP_IO))
   u_system(
      .clk_lpt       (clk_lct),
      .clk_hpt       (clk_hct),
      .clk_debug     (clk_debug),
      .clk_noc       (clk_noc),
      .rst           (sys_rst),

      .c_glip_in     (c_glip_in),
      .c_glip_out    (c_glip_out),

      .wb_ext_adr_i  (wb_ext_adr_i),
      .wb_ext_cyc_i  (wb_ext_cyc_i),
      .wb_ext_dat_i  (wb_ext_dat_i),
      .wb_ext_sel_i  (wb_ext_sel_i),
      .wb_ext_stb_i  (wb_ext_stb_i),
      .wb_ext_we_i   (wb_ext_we_i),
      .wb_ext_cab_i  (), // XXX: this is an old signal not present in WB B3 any more!?
      .wb_ext_cti_i  (wb_ext_cti_i),
      .wb_ext_bte_i  (wb_ext_bte_i),
      .wb_ext_ack_o  (wb_ext_ack_o),
      .wb_ext_rty_o  (wb_ext_rty_o),
      .wb_ext_err_o  (wb_ext_err_o),
      .wb_ext_dat_o  (wb_ext_dat_o)
   );

   // Board wrapper
   nexysVideo
      u_board(
         // FPGA/board interface
         .clk_i            (clk),
         .cpu_rst_n        (cpu_rst_n),

         .ddr3_dq          (ddr3_dq),
         .ddr3_dqs_n       (ddr3_dqs_n),
         .ddr3_dqs_p       (ddr3_dqs_p),
         .ddr3_addr        (ddr3_addr),
         .ddr3_ba          (ddr3_ba),
         .ddr3_ras_n       (ddr3_ras_n),
         .ddr3_cas_n       (ddr3_cas_n),
         .ddr3_we_n        (ddr3_we_n),
         .ddr3_reset_n     (ddr3_reset_n),
         .ddr3_ck_p        (ddr3_ck_p),
         .ddr3_ck_n        (ddr3_ck_n),
         .ddr3_cke         (ddr3_cke),
         .ddr3_dm          (ddr3_dm),
         .ddr3_odt         (ddr3_odt),

         // System interface
         .sys_clk_100      (sys_clk_100),
         .sys_clk_50       (sys_clk_50),
         .sys_rst          (sys_rst_board),

         .ddr_awid         (c_axi_ddr_board.aw_id),
         .ddr_awaddr       (c_axi_ddr_board.aw_addr),
         .ddr_awlen        (c_axi_ddr_board.aw_len),
         .ddr_awsize       (c_axi_ddr_board.aw_size),
         .ddr_awburst      (c_axi_ddr_board.aw_burst),
         .ddr_awlock       (1'b0), // unused
         .ddr_awcache      (c_axi_ddr_board.aw_cache),
         .ddr_awprot       (c_axi_ddr_board.aw_prot),
         .ddr_awqos        (c_axi_ddr_board.aw_qos),
         .ddr_awvalid      (c_axi_ddr_board.aw_valid),
         .ddr_awready      (c_axi_ddr_board.aw_ready),
         .ddr_wdata        (c_axi_ddr_board.w_data),
         .ddr_wstrb        (c_axi_ddr_board.w_strb),
         .ddr_wlast        (c_axi_ddr_board.w_last),
         .ddr_wvalid       (c_axi_ddr_board.w_valid),
         .ddr_wready       (c_axi_ddr_board.w_ready),
         .ddr_bid          (c_axi_ddr_board.b_id),
         .ddr_bresp        (c_axi_ddr_board.b_resp),
         .ddr_bvalid       (c_axi_ddr_board.b_valid),
         .ddr_bready       (c_axi_ddr_board.b_ready),
         .ddr_arid         (c_axi_ddr_board.ar_id),
         .ddr_araddr       (c_axi_ddr_board.ar_addr),
         .ddr_arlen        (c_axi_ddr_board.ar_len),
         .ddr_arsize       (c_axi_ddr_board.ar_size),
         .ddr_arburst      (c_axi_ddr_board.ar_burst),
         .ddr_arlock       (1'b0), // unused
         .ddr_arcache      (c_axi_ddr_board.ar_cache),
         .ddr_arprot       (c_axi_ddr_board.ar_prot),
         .ddr_arqos        (c_axi_ddr_board.ar_qos),
         .ddr_arvalid      (c_axi_ddr_board.ar_valid),
         .ddr_arready      (c_axi_ddr_board.ar_ready),
         .ddr_rid          (c_axi_ddr_board.r_id),
         .ddr_rresp        (c_axi_ddr_board.r_resp),
         .ddr_rdata        (c_axi_ddr_board.r_data),
         .ddr_rlast        (c_axi_ddr_board.r_last),
         .ddr_rvalid       (c_axi_ddr_board.r_valid),
         .ddr_rready       (c_axi_ddr_board.r_ready)
      );

   generate
      for (i = 0; i < TILES; i++) begin : wb2axi_interface
         // Memory interface: convert WishBone signals from system to AXI for DRAM
         wb2axi #(
            .ADDR_WIDTH (TILE_ADDR_WIDTH),
            .DATA_WIDTH (DDR_DATA_WIDTH),
            .AXI_ID_WIDTH (0))
         u_wb2axi_ddr(
            .clk              (sys_clk_50),
            .rst              (sys_rst),
            .wb_cyc_i         (c_wb_ddr[i].cyc_o),
            .wb_stb_i         (c_wb_ddr[i].stb_o),
            .wb_we_i          (c_wb_ddr[i].we_o),
            .wb_adr_i         (c_wb_ddr[i].adr_o[TILE_ADDR_WIDTH-1:0]),
            .wb_dat_i         (c_wb_ddr[i].dat_o),
            .wb_sel_i         (c_wb_ddr[i].sel_o),
            .wb_cti_i         (c_wb_ddr[i].cti_o),
            .wb_bte_i         (c_wb_ddr[i].bte_o),
            .wb_ack_o         (c_wb_ddr[i].ack_i),
            .wb_err_o         (c_wb_ddr[i].err_i),
            .wb_rty_o         (c_wb_ddr[i].rty_i),
            .wb_dat_o         (c_wb_ddr[i].dat_i),
            .m_axi_awid       (c_axi_tile[i].aw_id),
            .m_axi_awaddr     (c_axi_tile[i].aw_addr),
            .m_axi_awlen      (c_axi_tile[i].aw_len),
            .m_axi_awsize     (c_axi_tile[i].aw_size),
            .m_axi_awburst    (c_axi_tile[i].aw_burst),
            .m_axi_awcache    (c_axi_tile[i].aw_cache),
            .m_axi_awprot     (c_axi_tile[i].aw_prot),
            .m_axi_awqos      (c_axi_tile[i].aw_qos),
            .m_axi_awvalid    (c_axi_tile[i].aw_valid),
            .m_axi_awready    (c_axi_tile[i].aw_ready),
            .m_axi_wdata      (c_axi_tile[i].w_data),
            .m_axi_wstrb      (c_axi_tile[i].w_strb),
            .m_axi_wlast      (c_axi_tile[i].w_last),
            .m_axi_wvalid     (c_axi_tile[i].w_valid),
            .m_axi_wready     (c_axi_tile[i].w_ready),
            .m_axi_bid        (c_axi_tile[i].b_id),
            .m_axi_bresp      (c_axi_tile[i].b_resp),
            .m_axi_bvalid     (c_axi_tile[i].b_valid),
            .m_axi_bready     (c_axi_tile[i].b_ready),
            .m_axi_arid       (c_axi_tile[i].ar_id),
            .m_axi_araddr     (c_axi_tile[i].ar_addr),
            .m_axi_arlen      (c_axi_tile[i].ar_len),
            .m_axi_arsize     (c_axi_tile[i].ar_size),
            .m_axi_arburst    (c_axi_tile[i].ar_burst),
            .m_axi_arcache    (c_axi_tile[i].ar_cache),
            .m_axi_arprot     (c_axi_tile[i].ar_prot),
            .m_axi_arqos      (c_axi_tile[i].ar_qos),
            .m_axi_arvalid    (c_axi_tile[i].ar_valid),
            .m_axi_arready    (c_axi_tile[i].ar_ready),
            .m_axi_rid        (c_axi_tile[i].r_id),
            .m_axi_rdata      (c_axi_tile[i].r_data),
            .m_axi_rresp      (c_axi_tile[i].r_resp),
            .m_axi_rlast      (c_axi_tile[i].r_last),
            .m_axi_rvalid     (c_axi_tile[i].r_valid),
            .m_axi_rready     (c_axi_tile[i].r_ready)
         );

         assign c_axi_tile[i].aw_lock = 1'h0;
         assign c_axi_tile[i].aw_region = 4'h0;
         assign c_axi_tile[i].ar_lock = 1'h0;
         assign c_axi_tile[i].ar_region = 4'h0;

         xilinx_axi_register_slice
         u_slice(
            .aclk             (sys_clk_50),
            .aresetn          (!sys_rst),
            .s_axi_awaddr     (c_axi_tile[i].aw_addr),
            .s_axi_awlen      (c_axi_tile[i].aw_len),
            .s_axi_awsize     (c_axi_tile[i].aw_size),
            .s_axi_awburst    (c_axi_tile[i].aw_burst),
            .s_axi_awlock     (c_axi_tile[i].aw_lock),
            .s_axi_awcache    (c_axi_tile[i].aw_cache),
            .s_axi_awprot     (c_axi_tile[i].aw_prot),
            .s_axi_awregion   (c_axi_tile[i].aw_region),
            .s_axi_awqos      (c_axi_tile[i].aw_qos),
            .s_axi_awvalid    (c_axi_tile[i].aw_valid),
            .s_axi_awready    (c_axi_tile[i].aw_ready),
            .s_axi_wdata      (c_axi_tile[i].w_data),
            .s_axi_wstrb      (c_axi_tile[i].w_strb),
            .s_axi_wlast      (c_axi_tile[i].w_last),
            .s_axi_wvalid     (c_axi_tile[i].w_valid),
            .s_axi_wready     (c_axi_tile[i].w_ready),
            .s_axi_bresp      (c_axi_tile[i].b_resp),
            .s_axi_bvalid     (c_axi_tile[i].b_valid),
            .s_axi_bready     (c_axi_tile[i].b_ready),
            .s_axi_araddr     (c_axi_tile[i].ar_addr),
            .s_axi_arlen      (c_axi_tile[i].ar_len),
            .s_axi_arsize     (c_axi_tile[i].ar_size),
            .s_axi_arburst    (c_axi_tile[i].ar_burst),
            .s_axi_arlock     (c_axi_tile[i].ar_lock),
            .s_axi_arcache    (c_axi_tile[i].ar_cache),
            .s_axi_arprot     (c_axi_tile[i].ar_prot),
            .s_axi_arregion   (c_axi_tile[i].ar_region),
            .s_axi_arqos      (c_axi_tile[i].ar_qos),
            .s_axi_arvalid    (c_axi_tile[i].ar_valid),
            .s_axi_arready    (c_axi_tile[i].ar_ready),
            .s_axi_rdata      (c_axi_tile[i].r_data),
            .s_axi_rresp      (c_axi_tile[i].r_resp),
            .s_axi_rlast      (c_axi_tile[i].r_last),
            .s_axi_rvalid     (c_axi_tile[i].r_valid),
            .s_axi_rready     (c_axi_tile[i].r_ready),
            .m_axi_awaddr     (c_axi_ddr[i].aw_addr),
            .m_axi_awlen      (c_axi_ddr[i].aw_len),
            .m_axi_awsize     (c_axi_ddr[i].aw_size),
            .m_axi_awburst    (c_axi_ddr[i].aw_burst),
            .m_axi_awlock     (c_axi_ddr[i].aw_lock),
            .m_axi_awcache    (c_axi_ddr[i].aw_cache),
            .m_axi_awprot     (c_axi_ddr[i].aw_prot),
            .m_axi_awregion   (c_axi_ddr[i].aw_region),
            .m_axi_awqos      (c_axi_ddr[i].aw_qos),
            .m_axi_awvalid    (c_axi_ddr[i].aw_valid),
            .m_axi_awready    (c_axi_ddr[i].aw_ready),
            .m_axi_wdata      (c_axi_ddr[i].w_data),
            .m_axi_wstrb      (c_axi_ddr[i].w_strb),
            .m_axi_wlast      (c_axi_ddr[i].w_last),
            .m_axi_wvalid     (c_axi_ddr[i].w_valid),
            .m_axi_wready     (c_axi_ddr[i].w_ready),
            .m_axi_bresp      (c_axi_ddr[i].b_resp),
            .m_axi_bvalid     (c_axi_ddr[i].b_valid),
            .m_axi_bready     (c_axi_ddr[i].b_ready),
            .m_axi_araddr     (c_axi_ddr[i].ar_addr),
            .m_axi_arlen      (c_axi_ddr[i].ar_len),
            .m_axi_arsize     (c_axi_ddr[i].ar_size),
            .m_axi_arburst    (c_axi_ddr[i].ar_burst),
            .m_axi_arlock     (c_axi_ddr[i].ar_lock),
            .m_axi_arcache    (c_axi_ddr[i].ar_cache),
            .m_axi_arprot     (c_axi_ddr[i].ar_prot),
            .m_axi_arregion   (c_axi_ddr[i].ar_region),
            .m_axi_arqos      (c_axi_ddr[i].ar_qos),
            .m_axi_arvalid    (c_axi_ddr[i].ar_valid),
            .m_axi_arready    (c_axi_ddr[i].ar_ready),
            .m_axi_rdata      (c_axi_ddr[i].r_data),
            .m_axi_rresp      (c_axi_ddr[i].r_resp),
            .m_axi_rlast      (c_axi_ddr[i].r_last),
            .m_axi_rvalid     (c_axi_ddr[i].r_valid),
            .m_axi_rready     (c_axi_ddr[i].r_ready)
         );
      end
   endgenerate

   xilinx_axi_interconnect_9to1
   u_axi_interconnect(
      .INTERCONNECT_ACLK      (sys_clk_50),
      .INTERCONNECT_ARESETN   (!sys_rst),

      .S00_AXI_ARESET_OUT_N   (!sys_rst),
      .S00_AXI_ACLK           (sys_clk_50),
      .S00_AXI_AWID           (0),
      .S00_AXI_AWADDR         ({4'h0, c_axi_ddr[0].aw_addr}),
      .S00_AXI_AWLEN          (c_axi_ddr[0].aw_len),
      .S00_AXI_AWSIZE         (c_axi_ddr[0].aw_size),
      .S00_AXI_AWBURST        (c_axi_ddr[0].aw_burst),
      .S00_AXI_AWLOCK         (0),
      .S00_AXI_AWCACHE        (c_axi_ddr[0].aw_cache),
      .S00_AXI_AWPROT         (c_axi_ddr[0].aw_prot),
      .S00_AXI_AWQOS          (c_axi_ddr[0].aw_qos),
      .S00_AXI_AWVALID        (c_axi_ddr[0].aw_valid),
      .S00_AXI_AWREADY        (c_axi_ddr[0].aw_ready),
      .S00_AXI_WDATA          (c_axi_ddr[0].w_data),
      .S00_AXI_WSTRB          (c_axi_ddr[0].w_strb),
      .S00_AXI_WLAST          (c_axi_ddr[0].w_last),
      .S00_AXI_WVALID         (c_axi_ddr[0].w_valid),
      .S00_AXI_WREADY         (c_axi_ddr[0].w_ready),
      .S00_AXI_BID            (),
      .S00_AXI_BRESP          (c_axi_ddr[0].b_resp),
      .S00_AXI_BVALID         (c_axi_ddr[0].b_valid),
      .S00_AXI_BREADY         (c_axi_ddr[0].b_ready),
      .S00_AXI_ARID           (0),
      .S00_AXI_ARADDR         ({4'h0, c_axi_ddr[0].ar_addr}),
      .S00_AXI_ARLEN          (c_axi_ddr[0].ar_len),
      .S00_AXI_ARSIZE         (c_axi_ddr[0].ar_size),
      .S00_AXI_ARBURST        (c_axi_ddr[0].ar_burst),
      .S00_AXI_ARLOCK         (0),
      .S00_AXI_ARCACHE        (c_axi_ddr[0].ar_cache),
      .S00_AXI_ARPROT         (c_axi_ddr[0].ar_prot),
      .S00_AXI_ARQOS          (c_axi_ddr[0].ar_qos),
      .S00_AXI_ARVALID        (c_axi_ddr[0].ar_valid),
      .S00_AXI_ARREADY        (c_axi_ddr[0].ar_ready),
      .S00_AXI_RID            (),
      .S00_AXI_RDATA          (c_axi_ddr[0].r_data),
      .S00_AXI_RRESP          (c_axi_ddr[0].r_resp),
      .S00_AXI_RLAST          (c_axi_ddr[0].r_last),
      .S00_AXI_RVALID         (c_axi_ddr[0].r_valid),
      .S00_AXI_RREADY         (c_axi_ddr[0].r_ready),

      .S01_AXI_ARESET_OUT_N   (!sys_rst),
      .S01_AXI_ACLK           (sys_clk_50),
      .S01_AXI_AWID           (0),
      .S01_AXI_AWADDR         ({4'h1, c_axi_ddr[1].aw_addr}),
      .S01_AXI_AWLEN          (c_axi_ddr[1].aw_len),
      .S01_AXI_AWSIZE         (c_axi_ddr[1].aw_size),
      .S01_AXI_AWBURST        (c_axi_ddr[1].aw_burst),
      .S01_AXI_AWLOCK         (0),
      .S01_AXI_AWCACHE        (c_axi_ddr[1].aw_cache),
      .S01_AXI_AWPROT         (c_axi_ddr[1].aw_prot),
      .S01_AXI_AWQOS          (c_axi_ddr[1].aw_qos),
      .S01_AXI_AWVALID        (c_axi_ddr[1].aw_valid),
      .S01_AXI_AWREADY        (c_axi_ddr[1].aw_ready),
      .S01_AXI_WDATA          (c_axi_ddr[1].w_data),
      .S01_AXI_WSTRB          (c_axi_ddr[1].w_strb),
      .S01_AXI_WLAST          (c_axi_ddr[1].w_last),
      .S01_AXI_WVALID         (c_axi_ddr[1].w_valid),
      .S01_AXI_WREADY         (c_axi_ddr[1].w_ready),
      .S01_AXI_BID            (),
      .S01_AXI_BRESP          (c_axi_ddr[1].b_resp),
      .S01_AXI_BVALID         (c_axi_ddr[1].b_valid),
      .S01_AXI_BREADY         (c_axi_ddr[1].b_ready),
      .S01_AXI_ARID           (0),
      .S01_AXI_ARADDR         ({4'h1, c_axi_ddr[1].ar_addr}),
      .S01_AXI_ARLEN          (c_axi_ddr[1].ar_len),
      .S01_AXI_ARSIZE         (c_axi_ddr[1].ar_size),
      .S01_AXI_ARBURST        (c_axi_ddr[1].ar_burst),
      .S01_AXI_ARLOCK         (0),
      .S01_AXI_ARCACHE        (c_axi_ddr[1].ar_cache),
      .S01_AXI_ARPROT         (c_axi_ddr[1].ar_prot),
      .S01_AXI_ARQOS          (c_axi_ddr[1].ar_qos),
      .S01_AXI_ARVALID        (c_axi_ddr[1].ar_valid),
      .S01_AXI_ARREADY        (c_axi_ddr[1].ar_ready),
      .S01_AXI_RID            (),
      .S01_AXI_RDATA          (c_axi_ddr[1].r_data),
      .S01_AXI_RRESP          (c_axi_ddr[1].r_resp),
      .S01_AXI_RLAST          (c_axi_ddr[1].r_last),
      .S01_AXI_RVALID         (c_axi_ddr[1].r_valid),
      .S01_AXI_RREADY         (c_axi_ddr[1].r_ready),

      .S02_AXI_ARESET_OUT_N   (!sys_rst),
      .S02_AXI_ACLK           (sys_clk_50),
      .S02_AXI_AWID           (0),
      .S02_AXI_AWADDR         ({4'h2, c_axi_ddr[2].aw_addr}),
      .S02_AXI_AWLEN          (c_axi_ddr[2].aw_len),
      .S02_AXI_AWSIZE         (c_axi_ddr[2].aw_size),
      .S02_AXI_AWBURST        (c_axi_ddr[2].aw_burst),
      .S02_AXI_AWLOCK         (0),
      .S02_AXI_AWCACHE        (c_axi_ddr[2].aw_cache),
      .S02_AXI_AWPROT         (c_axi_ddr[2].aw_prot),
      .S02_AXI_AWQOS          (c_axi_ddr[2].aw_qos),
      .S02_AXI_AWVALID        (c_axi_ddr[2].aw_valid),
      .S02_AXI_AWREADY        (c_axi_ddr[2].aw_ready),
      .S02_AXI_WDATA          (c_axi_ddr[2].w_data),
      .S02_AXI_WSTRB          (c_axi_ddr[2].w_strb),
      .S02_AXI_WLAST          (c_axi_ddr[2].w_last),
      .S02_AXI_WVALID         (c_axi_ddr[2].w_valid),
      .S02_AXI_WREADY         (c_axi_ddr[2].w_ready),
      .S02_AXI_BID            (),
      .S02_AXI_BRESP          (c_axi_ddr[2].b_resp),
      .S02_AXI_BVALID         (c_axi_ddr[2].b_valid),
      .S02_AXI_BREADY         (c_axi_ddr[2].b_ready),
      .S02_AXI_ARID           (0),
      .S02_AXI_ARADDR         ({4'h2, c_axi_ddr[2].ar_addr}),
      .S02_AXI_ARLEN          (c_axi_ddr[2].ar_len),
      .S02_AXI_ARSIZE         (c_axi_ddr[2].ar_size),
      .S02_AXI_ARBURST        (c_axi_ddr[2].ar_burst),
      .S02_AXI_ARLOCK         (0),
      .S02_AXI_ARCACHE        (c_axi_ddr[2].ar_cache),
      .S02_AXI_ARPROT         (c_axi_ddr[2].ar_prot),
      .S02_AXI_ARQOS          (c_axi_ddr[2].ar_qos),
      .S02_AXI_ARVALID        (c_axi_ddr[2].ar_valid),
      .S02_AXI_ARREADY        (c_axi_ddr[2].ar_ready),
      .S02_AXI_RID            (),
      .S02_AXI_RDATA          (c_axi_ddr[2].r_data),
      .S02_AXI_RRESP          (c_axi_ddr[2].r_resp),
      .S02_AXI_RLAST          (c_axi_ddr[2].r_last),
      .S02_AXI_RVALID         (c_axi_ddr[2].r_valid),
      .S02_AXI_RREADY         (c_axi_ddr[2].r_ready),

      .S03_AXI_ARESET_OUT_N   (!sys_rst),
      .S03_AXI_ACLK           (sys_clk_50),
      .S03_AXI_AWID           (0),
      .S03_AXI_AWADDR         ({4'h3, c_axi_ddr[3].aw_addr}),
      .S03_AXI_AWLEN          (c_axi_ddr[3].aw_len),
      .S03_AXI_AWSIZE         (c_axi_ddr[3].aw_size),
      .S03_AXI_AWBURST        (c_axi_ddr[3].aw_burst),
      .S03_AXI_AWLOCK         (0),
      .S03_AXI_AWCACHE        (c_axi_ddr[3].aw_cache),
      .S03_AXI_AWPROT         (c_axi_ddr[3].aw_prot),
      .S03_AXI_AWQOS          (c_axi_ddr[3].aw_qos),
      .S03_AXI_AWVALID        (c_axi_ddr[3].aw_valid),
      .S03_AXI_AWREADY        (c_axi_ddr[3].aw_ready),
      .S03_AXI_WDATA          (c_axi_ddr[3].w_data),
      .S03_AXI_WSTRB          (c_axi_ddr[3].w_strb),
      .S03_AXI_WLAST          (c_axi_ddr[3].w_last),
      .S03_AXI_WVALID         (c_axi_ddr[3].w_valid),
      .S03_AXI_WREADY         (c_axi_ddr[3].w_ready),
      .S03_AXI_BID            (),
      .S03_AXI_BRESP          (c_axi_ddr[3].b_resp),
      .S03_AXI_BVALID         (c_axi_ddr[3].b_valid),
      .S03_AXI_BREADY         (c_axi_ddr[3].b_ready),
      .S03_AXI_ARID           (0),
      .S03_AXI_ARADDR         ({4'h3, c_axi_ddr[3].ar_addr}),
      .S03_AXI_ARLEN          (c_axi_ddr[3].ar_len),
      .S03_AXI_ARSIZE         (c_axi_ddr[3].ar_size),
      .S03_AXI_ARBURST        (c_axi_ddr[3].ar_burst),
      .S03_AXI_ARLOCK         (0),
      .S03_AXI_ARCACHE        (c_axi_ddr[3].ar_cache),
      .S03_AXI_ARPROT         (c_axi_ddr[3].ar_prot),
      .S03_AXI_ARQOS          (c_axi_ddr[3].ar_qos),
      .S03_AXI_ARVALID        (c_axi_ddr[3].ar_valid),
      .S03_AXI_ARREADY        (c_axi_ddr[3].ar_ready),
      .S03_AXI_RID            (),
      .S03_AXI_RDATA          (c_axi_ddr[3].r_data),
      .S03_AXI_RRESP          (c_axi_ddr[3].r_resp),
      .S03_AXI_RLAST          (c_axi_ddr[3].r_last),
      .S03_AXI_RVALID         (c_axi_ddr[3].r_valid),
      .S03_AXI_RREADY         (c_axi_ddr[3].r_ready),

      .S04_AXI_ARESET_OUT_N   (!sys_rst),
      .S04_AXI_ACLK           (sys_clk_50),
      .S04_AXI_AWID           (0),
      .S04_AXI_AWADDR         ({4'h4, c_axi_ddr[4].aw_addr}),
      .S04_AXI_AWLEN          (c_axi_ddr[4].aw_len),
      .S04_AXI_AWSIZE         (c_axi_ddr[4].aw_size),
      .S04_AXI_AWBURST        (c_axi_ddr[4].aw_burst),
      .S04_AXI_AWLOCK         (0),
      .S04_AXI_AWCACHE        (c_axi_ddr[4].aw_cache),
      .S04_AXI_AWPROT         (c_axi_ddr[4].aw_prot),
      .S04_AXI_AWQOS          (c_axi_ddr[4].aw_qos),
      .S04_AXI_AWVALID        (c_axi_ddr[4].aw_valid),
      .S04_AXI_AWREADY        (c_axi_ddr[4].aw_ready),
      .S04_AXI_WDATA          (c_axi_ddr[4].w_data),
      .S04_AXI_WSTRB          (c_axi_ddr[4].w_strb),
      .S04_AXI_WLAST          (c_axi_ddr[4].w_last),
      .S04_AXI_WVALID         (c_axi_ddr[4].w_valid),
      .S04_AXI_WREADY         (c_axi_ddr[4].w_ready),
      .S04_AXI_BID            (),
      .S04_AXI_BRESP          (c_axi_ddr[4].b_resp),
      .S04_AXI_BVALID         (c_axi_ddr[4].b_valid),
      .S04_AXI_BREADY         (c_axi_ddr[4].b_ready),
      .S04_AXI_ARID           (0),
      .S04_AXI_ARADDR         ({4'h4, c_axi_ddr[4].ar_addr}),
      .S04_AXI_ARLEN          (c_axi_ddr[4].ar_len),
      .S04_AXI_ARSIZE         (c_axi_ddr[4].ar_size),
      .S04_AXI_ARBURST        (c_axi_ddr[4].ar_burst),
      .S04_AXI_ARLOCK         (0),
      .S04_AXI_ARCACHE        (c_axi_ddr[4].ar_cache),
      .S04_AXI_ARPROT         (c_axi_ddr[4].ar_prot),
      .S04_AXI_ARQOS          (c_axi_ddr[4].ar_qos),
      .S04_AXI_ARVALID        (c_axi_ddr[4].ar_valid),
      .S04_AXI_ARREADY        (c_axi_ddr[4].ar_ready),
      .S04_AXI_RID            (),
      .S04_AXI_RDATA          (c_axi_ddr[4].r_data),
      .S04_AXI_RRESP          (c_axi_ddr[4].r_resp),
      .S04_AXI_RLAST          (c_axi_ddr[4].r_last),
      .S04_AXI_RVALID         (c_axi_ddr[4].r_valid),
      .S04_AXI_RREADY         (c_axi_ddr[4].r_ready),

      .S05_AXI_ARESET_OUT_N   (!sys_rst),
      .S05_AXI_ACLK           (sys_clk_50),
      .S05_AXI_AWID           (0),
      .S05_AXI_AWADDR         ({4'h5, c_axi_ddr[5].aw_addr}),
      .S05_AXI_AWLEN          (c_axi_ddr[5].aw_len),
      .S05_AXI_AWSIZE         (c_axi_ddr[5].aw_size),
      .S05_AXI_AWBURST        (c_axi_ddr[5].aw_burst),
      .S05_AXI_AWLOCK         (0),
      .S05_AXI_AWCACHE        (c_axi_ddr[5].aw_cache),
      .S05_AXI_AWPROT         (c_axi_ddr[5].aw_prot),
      .S05_AXI_AWQOS          (c_axi_ddr[5].aw_qos),
      .S05_AXI_AWVALID        (c_axi_ddr[5].aw_valid),
      .S05_AXI_AWREADY        (c_axi_ddr[5].aw_ready),
      .S05_AXI_WDATA          (c_axi_ddr[5].w_data),
      .S05_AXI_WSTRB          (c_axi_ddr[5].w_strb),
      .S05_AXI_WLAST          (c_axi_ddr[5].w_last),
      .S05_AXI_WVALID         (c_axi_ddr[5].w_valid),
      .S05_AXI_WREADY         (c_axi_ddr[5].w_ready),
      .S05_AXI_BID            (),
      .S05_AXI_BRESP          (c_axi_ddr[5].b_resp),
      .S05_AXI_BVALID         (c_axi_ddr[5].b_valid),
      .S05_AXI_BREADY         (c_axi_ddr[5].b_ready),
      .S05_AXI_ARID           (0),
      .S05_AXI_ARADDR         ({4'h5, c_axi_ddr[5].ar_addr}),
      .S05_AXI_ARLEN          (c_axi_ddr[5].ar_len),
      .S05_AXI_ARSIZE         (c_axi_ddr[5].ar_size),
      .S05_AXI_ARBURST        (c_axi_ddr[5].ar_burst),
      .S05_AXI_ARLOCK         (0),
      .S05_AXI_ARCACHE        (c_axi_ddr[5].ar_cache),
      .S05_AXI_ARPROT         (c_axi_ddr[5].ar_prot),
      .S05_AXI_ARQOS          (c_axi_ddr[5].ar_qos),
      .S05_AXI_ARVALID        (c_axi_ddr[5].ar_valid),
      .S05_AXI_ARREADY        (c_axi_ddr[5].ar_ready),
      .S05_AXI_RID            (),
      .S05_AXI_RDATA          (c_axi_ddr[5].r_data),
      .S05_AXI_RRESP          (c_axi_ddr[5].r_resp),
      .S05_AXI_RLAST          (c_axi_ddr[5].r_last),
      .S05_AXI_RVALID         (c_axi_ddr[5].r_valid),
      .S05_AXI_RREADY         (c_axi_ddr[5].r_ready),

      .S06_AXI_ARESET_OUT_N   (!sys_rst),
      .S06_AXI_ACLK           (sys_clk_50),
      .S06_AXI_AWID           (0),
      .S06_AXI_AWADDR         ({4'h6, c_axi_ddr[6].aw_addr}),
      .S06_AXI_AWLEN          (c_axi_ddr[6].aw_len),
      .S06_AXI_AWSIZE         (c_axi_ddr[6].aw_size),
      .S06_AXI_AWBURST        (c_axi_ddr[6].aw_burst),
      .S06_AXI_AWLOCK         (0),
      .S06_AXI_AWCACHE        (c_axi_ddr[6].aw_cache),
      .S06_AXI_AWPROT         (c_axi_ddr[6].aw_prot),
      .S06_AXI_AWQOS          (c_axi_ddr[6].aw_qos),
      .S06_AXI_AWVALID        (c_axi_ddr[6].aw_valid),
      .S06_AXI_AWREADY        (c_axi_ddr[6].aw_ready),
      .S06_AXI_WDATA          (c_axi_ddr[6].w_data),
      .S06_AXI_WSTRB          (c_axi_ddr[6].w_strb),
      .S06_AXI_WLAST          (c_axi_ddr[6].w_last),
      .S06_AXI_WVALID         (c_axi_ddr[6].w_valid),
      .S06_AXI_WREADY         (c_axi_ddr[6].w_ready),
      .S06_AXI_BID            (),
      .S06_AXI_BRESP          (c_axi_ddr[6].b_resp),
      .S06_AXI_BVALID         (c_axi_ddr[6].b_valid),
      .S06_AXI_BREADY         (c_axi_ddr[6].b_ready),
      .S06_AXI_ARID           (0),
      .S06_AXI_ARADDR         ({4'h6, c_axi_ddr[6].ar_addr}),
      .S06_AXI_ARLEN          (c_axi_ddr[6].ar_len),
      .S06_AXI_ARSIZE         (c_axi_ddr[6].ar_size),
      .S06_AXI_ARBURST        (c_axi_ddr[6].ar_burst),
      .S06_AXI_ARLOCK         (0),
      .S06_AXI_ARCACHE        (c_axi_ddr[6].ar_cache),
      .S06_AXI_ARPROT         (c_axi_ddr[6].ar_prot),
      .S06_AXI_ARQOS          (c_axi_ddr[6].ar_qos),
      .S06_AXI_ARVALID        (c_axi_ddr[6].ar_valid),
      .S06_AXI_ARREADY        (c_axi_ddr[6].ar_ready),
      .S06_AXI_RID            (),
      .S06_AXI_RDATA          (c_axi_ddr[6].r_data),
      .S06_AXI_RRESP          (c_axi_ddr[6].r_resp),
      .S06_AXI_RLAST          (c_axi_ddr[6].r_last),
      .S06_AXI_RVALID         (c_axi_ddr[6].r_valid),
      .S06_AXI_RREADY         (c_axi_ddr[6].r_ready),

      .S07_AXI_ARESET_OUT_N   (!sys_rst),
      .S07_AXI_ACLK           (sys_clk_50),
      .S07_AXI_AWID           (0),
      .S07_AXI_AWADDR         ({4'h7, c_axi_ddr[7].aw_addr}),
      .S07_AXI_AWLEN          (c_axi_ddr[7].aw_len),
      .S07_AXI_AWSIZE         (c_axi_ddr[7].aw_size),
      .S07_AXI_AWBURST        (c_axi_ddr[7].aw_burst),
      .S07_AXI_AWLOCK         (0),
      .S07_AXI_AWCACHE        (c_axi_ddr[7].aw_cache),
      .S07_AXI_AWPROT         (c_axi_ddr[7].aw_prot),
      .S07_AXI_AWQOS          (c_axi_ddr[7].aw_qos),
      .S07_AXI_AWVALID        (c_axi_ddr[7].aw_valid),
      .S07_AXI_AWREADY        (c_axi_ddr[7].aw_ready),
      .S07_AXI_WDATA          (c_axi_ddr[7].w_data),
      .S07_AXI_WSTRB          (c_axi_ddr[7].w_strb),
      .S07_AXI_WLAST          (c_axi_ddr[7].w_last),
      .S07_AXI_WVALID         (c_axi_ddr[7].w_valid),
      .S07_AXI_WREADY         (c_axi_ddr[7].w_ready),
      .S07_AXI_BID            (),
      .S07_AXI_BRESP          (c_axi_ddr[7].b_resp),
      .S07_AXI_BVALID         (c_axi_ddr[7].b_valid),
      .S07_AXI_BREADY         (c_axi_ddr[7].b_ready),
      .S07_AXI_ARID           (0),
      .S07_AXI_ARADDR         ({4'h7, c_axi_ddr[7].ar_addr}),
      .S07_AXI_ARLEN          (c_axi_ddr[7].ar_len),
      .S07_AXI_ARSIZE         (c_axi_ddr[7].ar_size),
      .S07_AXI_ARBURST        (c_axi_ddr[7].ar_burst),
      .S07_AXI_ARLOCK         (0),
      .S07_AXI_ARCACHE        (c_axi_ddr[7].ar_cache),
      .S07_AXI_ARPROT         (c_axi_ddr[7].ar_prot),
      .S07_AXI_ARQOS          (c_axi_ddr[7].ar_qos),
      .S07_AXI_ARVALID        (c_axi_ddr[7].ar_valid),
      .S07_AXI_ARREADY        (c_axi_ddr[7].ar_ready),
      .S07_AXI_RID            (),
      .S07_AXI_RDATA          (c_axi_ddr[7].r_data),
      .S07_AXI_RRESP          (c_axi_ddr[7].r_resp),
      .S07_AXI_RLAST          (c_axi_ddr[7].r_last),
      .S07_AXI_RVALID         (c_axi_ddr[7].r_valid),
      .S07_AXI_RREADY         (c_axi_ddr[7].r_ready),

      .S08_AXI_ARESET_OUT_N   (!sys_rst),
      .S08_AXI_ACLK           (sys_clk_50),
      .S08_AXI_AWID           (0),
      .S08_AXI_AWADDR         ({4'h8, c_axi_ddr[8].aw_addr}),
      .S08_AXI_AWLEN          (c_axi_ddr[8].aw_len),
      .S08_AXI_AWSIZE         (c_axi_ddr[8].aw_size),
      .S08_AXI_AWBURST        (c_axi_ddr[8].aw_burst),
      .S08_AXI_AWLOCK         (0),
      .S08_AXI_AWCACHE        (c_axi_ddr[8].aw_cache),
      .S08_AXI_AWPROT         (c_axi_ddr[8].aw_prot),
      .S08_AXI_AWQOS          (c_axi_ddr[8].aw_qos),
      .S08_AXI_AWVALID        (c_axi_ddr[8].aw_valid),
      .S08_AXI_AWREADY        (c_axi_ddr[8].aw_ready),
      .S08_AXI_WDATA          (c_axi_ddr[8].w_data),
      .S08_AXI_WSTRB          (c_axi_ddr[8].w_strb),
      .S08_AXI_WLAST          (c_axi_ddr[8].w_last),
      .S08_AXI_WVALID         (c_axi_ddr[8].w_valid),
      .S08_AXI_WREADY         (c_axi_ddr[8].w_ready),
      .S08_AXI_BID            (),
      .S08_AXI_BRESP          (c_axi_ddr[8].b_resp),
      .S08_AXI_BVALID         (c_axi_ddr[8].b_valid),
      .S08_AXI_BREADY         (c_axi_ddr[8].b_ready),
      .S08_AXI_ARID           (0),
      .S08_AXI_ARADDR         ({4'h8, c_axi_ddr[8].ar_addr}),
      .S08_AXI_ARLEN          (c_axi_ddr[8].ar_len),
      .S08_AXI_ARSIZE         (c_axi_ddr[8].ar_size),
      .S08_AXI_ARBURST        (c_axi_ddr[8].ar_burst),
      .S08_AXI_ARLOCK         (0),
      .S08_AXI_ARCACHE        (c_axi_ddr[8].ar_cache),
      .S08_AXI_ARPROT         (c_axi_ddr[8].ar_prot),
      .S08_AXI_ARQOS          (c_axi_ddr[8].ar_qos),
      .S08_AXI_ARVALID        (c_axi_ddr[8].ar_valid),
      .S08_AXI_ARREADY        (c_axi_ddr[8].ar_ready),
      .S08_AXI_RID            (),
      .S08_AXI_RDATA          (c_axi_ddr[8].r_data),
      .S08_AXI_RRESP          (c_axi_ddr[8].r_resp),
      .S08_AXI_RLAST          (c_axi_ddr[8].r_last),
      .S08_AXI_RVALID         (c_axi_ddr[8].r_valid),
      .S08_AXI_RREADY         (c_axi_ddr[8].r_ready),

      .M00_AXI_ARESET_OUT_N   (!sys_rst),
      .M00_AXI_ACLK           (sys_clk_50),
      .M00_AXI_AWID           (c_axi_ddr_board.aw_id),
      .M00_AXI_AWADDR         (c_axi_ddr_board.aw_addr),
      .M00_AXI_AWLEN          (c_axi_ddr_board.aw_len),
      .M00_AXI_AWSIZE         (c_axi_ddr_board.aw_size),
      .M00_AXI_AWBURST        (c_axi_ddr_board.aw_burst),
      .M00_AXI_AWLOCK         (),
      .M00_AXI_AWCACHE        (c_axi_ddr_board.aw_cache),
      .M00_AXI_AWPROT         (c_axi_ddr_board.aw_prot),
      .M00_AXI_AWQOS          (c_axi_ddr_board.aw_qos),
      .M00_AXI_AWVALID        (c_axi_ddr_board.aw_valid),
      .M00_AXI_AWREADY        (c_axi_ddr_board.aw_ready),
      .M00_AXI_WDATA          (c_axi_ddr_board.w_data),
      .M00_AXI_WSTRB          (c_axi_ddr_board.w_strb),
      .M00_AXI_WLAST          (c_axi_ddr_board.w_last),
      .M00_AXI_WVALID         (c_axi_ddr_board.w_valid),
      .M00_AXI_WREADY         (c_axi_ddr_board.w_ready),
      .M00_AXI_BID            (c_axi_ddr_board.b_id),
      .M00_AXI_BRESP          (c_axi_ddr_board.b_resp),
      .M00_AXI_BVALID         (c_axi_ddr_board.b_valid),
      .M00_AXI_BREADY         (c_axi_ddr_board.b_ready),
      .M00_AXI_ARID           (c_axi_ddr_board.ar_id),
      .M00_AXI_ARADDR         (c_axi_ddr_board.ar_addr),
      .M00_AXI_ARLEN          (c_axi_ddr_board.ar_len),
      .M00_AXI_ARSIZE         (c_axi_ddr_board.ar_size),
      .M00_AXI_ARBURST        (c_axi_ddr_board.ar_burst),
      .M00_AXI_ARLOCK         (),
      .M00_AXI_ARCACHE        (c_axi_ddr_board.ar_cache),
      .M00_AXI_ARPROT         (c_axi_ddr_board.ar_prot),
      .M00_AXI_ARQOS          (c_axi_ddr_board.ar_qos),
      .M00_AXI_ARVALID        (c_axi_ddr_board.ar_valid),
      .M00_AXI_ARREADY        (c_axi_ddr_board.ar_ready),
      .M00_AXI_RID            (c_axi_ddr_board.r_id),
      .M00_AXI_RDATA          (c_axi_ddr_board.r_data),
      .M00_AXI_RRESP          (c_axi_ddr_board.r_resp),
      .M00_AXI_RLAST          (c_axi_ddr_board.r_last),
      .M00_AXI_RVALID         (c_axi_ddr_board.r_valid),
      .M00_AXI_RREADY         (c_axi_ddr_board.r_ready)
   );

endmodule // system_3x3_nexysVideo
