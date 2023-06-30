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
 * NexysVideo board abstraction
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de.de>
 */
module nexysVideo (
   // FPGA IO
   input             clk_i,
   input             cpu_rst_n,

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

   // System Interface
   output            sys_clk_100,
   output            sys_clk_50,
   output            sys_clk_25,
   output            sys_rst,

   input [3:0]       ddr_awid,
   input [31:0]      ddr_awaddr,
   input [7:0]       ddr_awlen,
   input [2:0]       ddr_awsize,
   input [1:0]       ddr_awburst,
   input [0:0]       ddr_awlock,
   input [3:0]       ddr_awcache,
   input [2:0]       ddr_awprot,
   input [3:0]       ddr_awqos,
   input             ddr_awvalid,
   output            ddr_awready,
   input [31:0]      ddr_wdata,
   input [3:0]       ddr_wstrb,
   input             ddr_wlast,
   input             ddr_wvalid,
   output            ddr_wready,
   output [3:0]      ddr_bid,
   output [1:0]      ddr_bresp,
   output            ddr_bvalid,
   input             ddr_bready,
   input [3:0]       ddr_arid,
   input [31:0]      ddr_araddr,
   input [7:0]       ddr_arlen,
   input [2:0]       ddr_arsize,
   input [1:0]       ddr_arburst,
   input [0:0]       ddr_arlock,
   input [3:0]       ddr_arcache,
   input [2:0]       ddr_arprot,
   input [3:0]       ddr_arqos,
   input             ddr_arvalid,
   output            ddr_arready,
   output [3:0]      ddr_rid,
   output [31:0]     ddr_rdata,
   output [1:0]      ddr_rresp,
   output            ddr_rlast,
   output            ddr_rvalid,
   input             ddr_rready
);

   wire rst;
   assign rst = cpu_rst_n;

   wire clk_ddr_ref; // 200 MHz clock for MIG
   wire clk_ddr_sys; // 100 MHz clock for MIG
   wire ddr_calib_done;
   wire ddr_mmcm_locked;
   wire mig_ui_rst; // Synchronized reset


   assign sys_rst = !(ddr_mmcm_locked & ddr_calib_done) | mig_ui_rst;


   // connection signals between the DRAM (slave) and the AXI clock converter
   // (master)
   wire [3:0]        ddr3_s_axi_awid;
   wire [28:0]       ddr3_s_axi_awaddr;
   wire [7:0]        ddr3_s_axi_awlen;
   wire [2:0]        ddr3_s_axi_awsize;
   wire [1:0]        ddr3_s_axi_awburst;
   wire [0:0]        ddr3_s_axi_awlock;
   wire [3:0]        ddr3_s_axi_awcache;
   wire [2:0]        ddr3_s_axi_awprot;
   wire [3:0]        ddr3_s_axi_awqos;
   wire              ddr3_s_axi_awvalid;
   wire              ddr3_s_axi_awready;
   wire [31:0]       ddr3_s_axi_wdata;
   wire [3:0]        ddr3_s_axi_wstrb;
   wire              ddr3_s_axi_wlast;
   wire              ddr3_s_axi_wvalid;
   wire              ddr3_s_axi_wready;
   wire              ddr3_s_axi_bready;
   wire [3:0]        ddr3_s_axi_bid;
   wire [1:0]        ddr3_s_axi_bresp;
   wire              ddr3_s_axi_bvalid;
   wire [3:0]        ddr3_s_axi_arid;
   wire [28:0]       ddr3_s_axi_araddr;
   wire [7:0]        ddr3_s_axi_arlen;
   wire [2:0]        ddr3_s_axi_arsize;
   wire [1:0]        ddr3_s_axi_arburst;
   wire [0:0]        ddr3_s_axi_arlock;
   wire [3:0]        ddr3_s_axi_arcache;
   wire [2:0]        ddr3_s_axi_arprot;
   wire [3:0]        ddr3_s_axi_arqos;
   wire              ddr3_s_axi_arvalid;
   wire              ddr3_s_axi_arready;
   wire              ddr3_s_axi_rready;
   wire [3:0]        ddr3_s_axi_rid;
   wire [31:0]       ddr3_s_axi_rdata;
   wire [1:0]        ddr3_s_axi_rresp;
   wire              ddr3_s_axi_rlast;
   wire              ddr3_s_axi_rvalid;


   mig_7series
     u_mig_7series
       (.init_calib_complete  (ddr_calib_done),
        .sys_clk_i            (clk_i),
        .clk_ref_i            (clk_ddr_ref),
        .sys_rst              (rst),

        // off-chip connection
        .ddr3_dq              (ddr3_dq),
        .ddr3_dqs_n           (ddr3_dqs_n),
        .ddr3_dqs_p           (ddr3_dqs_p),
        .ddr3_addr            (ddr3_addr),
        .ddr3_ba              (ddr3_ba),
        .ddr3_ras_n           (ddr3_ras_n),
        .ddr3_cas_n           (ddr3_cas_n),
        .ddr3_we_n            (ddr3_we_n),
        .ddr3_reset_n         (ddr3_reset_n),
        .ddr3_ck_p            (ddr3_ck_p),
        .ddr3_ck_n            (ddr3_ck_n),
        .ddr3_cke             (ddr3_cke),
        .ddr3_dm              (ddr3_dm),
        .ddr3_odt             (ddr3_odt),

        // Application interface ports
        .ui_clk               (sys_clk_100),
        .ui_clk_sync_rst      (mig_ui_rst),
        .mmcm_locked          (ddr_mmcm_locked),
        .aresetn              (~sys_rst),
        .app_sr_req           (0),
        .app_ref_req          (0),
        .app_zq_req           (0),
        .app_sr_active        (),
        .app_ref_ack          (),
        .app_zq_ack           (),

        .ui_addn_clk_0        (clk_ddr_ref),
        .ui_addn_clk_1        (sys_clk_50),
        .ui_addn_clk_2        (sys_clk_25),

        .device_temp          (),

        // Slave Interface Write Address Ports
        .s_axi_awid           (ddr3_s_axi_awid),
        .s_axi_awaddr         (ddr3_s_axi_awaddr),
        .s_axi_awlen          (ddr3_s_axi_awlen),
        .s_axi_awsize         (ddr3_s_axi_awsize),
        .s_axi_awburst        (ddr3_s_axi_awburst),
        .s_axi_awlock         (ddr3_s_axi_awlock),
        .s_axi_awcache        (ddr3_s_axi_awcache),
        .s_axi_awprot         (ddr3_s_axi_awprot),
        .s_axi_awqos          (ddr3_s_axi_awqos),
        .s_axi_awvalid        (ddr3_s_axi_awvalid),
        .s_axi_awready        (ddr3_s_axi_awready),
        // Slave Interface Write Data Ports
        .s_axi_wdata          (ddr3_s_axi_wdata),
        .s_axi_wstrb          (ddr3_s_axi_wstrb),
        .s_axi_wlast          (ddr3_s_axi_wlast),
        .s_axi_wvalid         (ddr3_s_axi_wvalid),
        .s_axi_wready         (ddr3_s_axi_wready),
        // Slave Interface Write Response Ports
        .s_axi_bid            (ddr3_s_axi_bid),
        .s_axi_bresp          (ddr3_s_axi_bresp),
        .s_axi_bvalid         (ddr3_s_axi_bvalid),
        .s_axi_bready         (ddr3_s_axi_bready),
        // Slave Interface Read Address Ports
        .s_axi_arid           (ddr3_s_axi_arid),
        .s_axi_araddr         (ddr3_s_axi_araddr),
        .s_axi_arlen          (ddr3_s_axi_arlen),
        .s_axi_arsize         (ddr3_s_axi_arsize),
        .s_axi_arburst        (ddr3_s_axi_arburst),
        .s_axi_arlock         (ddr3_s_axi_arlock),
        .s_axi_arcache        (ddr3_s_axi_arcache),
        .s_axi_arprot         (ddr3_s_axi_arprot),
        .s_axi_arqos          (ddr3_s_axi_arqos),
        .s_axi_arvalid        (ddr3_s_axi_arvalid),
        .s_axi_arready        (ddr3_s_axi_arready),
        // Slave Interface Read Data Ports
        .s_axi_rid            (ddr3_s_axi_rid),
        .s_axi_rdata          (ddr3_s_axi_rdata),
        .s_axi_rresp          (ddr3_s_axi_rresp),
        .s_axi_rlast          (ddr3_s_axi_rlast),
        .s_axi_rvalid         (ddr3_s_axi_rvalid),
        .s_axi_rready         (ddr3_s_axi_rready)
     );


     // cross the memory AXI bus from 100 MHz to 50 MHz
   ddr3_axi_clock_converter
      u_ddr3_axi_clock_converter(
         // AXI slave side for the outside world
         /**************** Write Address Channel Signals ****************/
         .s_axi_awaddr        (ddr_awaddr[28:0]),
         .s_axi_awprot        (ddr_awprot),
         .s_axi_awvalid       (ddr_awvalid),
         .s_axi_awready       (ddr_awready),
         .s_axi_awsize        (ddr_awsize),
         .s_axi_awburst       (ddr_awburst),
         .s_axi_awcache       (ddr_awcache),
         .s_axi_awlen         (ddr_awlen),
         .s_axi_awlock        (ddr_awlock),
         .s_axi_awqos         (ddr_awqos),
         .s_axi_awregion      (4'b0000), // not supported by MIG
         .s_axi_awid          (ddr_awid),
         /**************** Write Data Channel Signals ****************/
         .s_axi_wdata         (ddr_wdata),
         .s_axi_wstrb         (ddr_wstrb),
         .s_axi_wvalid        (ddr_wvalid),
         .s_axi_wready        (ddr_wready),
         .s_axi_wlast         (ddr_wlast),
         /**************** Write Response Channel Signals ****************/
         .s_axi_bresp         (ddr_bresp),
         .s_axi_bvalid        (ddr_bvalid),
         .s_axi_bready        (ddr_bready),
         .s_axi_bid           (ddr_bid),
         /**************** Read Address Channel Signals ****************/
         .s_axi_araddr        (ddr_araddr[28:0]),
         .s_axi_arprot        (ddr_arprot),
         .s_axi_arvalid       (ddr_arvalid),
         .s_axi_arready       (ddr_arready),
         .s_axi_arsize        (ddr_arsize),
         .s_axi_arburst       (ddr_arburst),
         .s_axi_arcache       (ddr_arcache),
         .s_axi_arlock        (ddr_arlock),
         .s_axi_arlen         (ddr_arlen),
         .s_axi_arqos         (ddr_arqos),
         .s_axi_arregion      (4'b0000), // not supported by MIG
         .s_axi_arid          (ddr_arid),
         /**************** Read Data Channel Signals ****************/
         .s_axi_rdata         (ddr_rdata),
         .s_axi_rresp         (ddr_rresp),
         .s_axi_rvalid        (ddr_rvalid),
         .s_axi_rready        (ddr_rready),
         .s_axi_rlast         (ddr_rlast),
         .s_axi_rid           (ddr_rid),
         /**************** System Signals ****************/
         .s_axi_aclk          (sys_clk_50),
         .s_axi_aresetn       (~sys_rst),

         // AXI master interface: connect to MIG
         /**************** Write Address Channel Signals ****************/
         .m_axi_awaddr        (ddr3_s_axi_awaddr),
         .m_axi_awprot        (ddr3_s_axi_awprot),
         .m_axi_awvalid       (ddr3_s_axi_awvalid),
         .m_axi_awready       (ddr3_s_axi_awready),
         .m_axi_awsize        (ddr3_s_axi_awsize),
         .m_axi_awburst       (ddr3_s_axi_awburst),
         .m_axi_awcache       (ddr3_s_axi_awcache),
         .m_axi_awlen         (ddr3_s_axi_awlen),
         .m_axi_awlock        (ddr3_s_axi_awlock),
         .m_axi_awqos         (ddr3_s_axi_awqos),
         .m_axi_awregion      (), // not supported by MIG
         .m_axi_awid          (ddr3_s_axi_awid),
         /**************** Write Data Channel Signals ****************/
         .m_axi_wdata         (ddr3_s_axi_wdata),
         .m_axi_wstrb         (ddr3_s_axi_wstrb),
         .m_axi_wvalid        (ddr3_s_axi_wvalid),
         .m_axi_wready        (ddr3_s_axi_wready),
         .m_axi_wlast         (ddr3_s_axi_wlast),
         /**************** Write Response Channel Signals ****************/
         .m_axi_bresp         (ddr3_s_axi_bresp),
         .m_axi_bvalid        (ddr3_s_axi_bvalid),
         .m_axi_bready        (ddr3_s_axi_bready),
         .m_axi_bid           (ddr3_s_axi_bid),
         /**************** Read Address Channel Signals ****************/
         .m_axi_araddr        (ddr3_s_axi_araddr),
         .m_axi_arprot        (ddr3_s_axi_arprot),
         .m_axi_arvalid       (ddr3_s_axi_arvalid),
         .m_axi_arready       (ddr3_s_axi_arready),
         .m_axi_arsize        (ddr3_s_axi_arsize),
         .m_axi_arburst       (ddr3_s_axi_arburst),
         .m_axi_arcache       (ddr3_s_axi_arcache),
         .m_axi_arlock        (ddr3_s_axi_arlock),
         .m_axi_arlen         (ddr3_s_axi_arlen),
         .m_axi_arqos         (ddr3_s_axi_arqos),
         .m_axi_arregion      (), // not supported by MIG
         .m_axi_arid          (ddr3_s_axi_arid),
         /**************** Read Data Channel Signals ****************/
         .m_axi_rdata         (ddr3_s_axi_rdata),
         .m_axi_rresp         (ddr3_s_axi_rresp),
         .m_axi_rvalid        (ddr3_s_axi_rvalid),
         .m_axi_rready        (ddr3_s_axi_rready),
         .m_axi_rlast         (ddr3_s_axi_rlast),
         .m_axi_rid           (ddr3_s_axi_rid),
         /**************** System Signals ****************/
         .m_axi_aclk          (sys_clk_100),
         .m_axi_aresetn       (~sys_rst)
      );

endmodule // nexysVideo
