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
 * This is a wrapper module for the noc control module to connect it to the
 * debug ring.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *
 */


import dii_package::dii_flit;

module noc_control_module_wrapper #(
   parameter DEBUG_BASEID = 'x,
   parameter MAX_DI_PKT_LEN = 12,
   parameter LUT_SIZE = 8,
   parameter MAX_PORTS = 8,   // I/O tile currently has 8 channels
   parameter X = 3,
   parameter Y = 3,
   parameter SIMPLE_NCM = 0,
   parameter ENABLE_FDM_FIM = 1,
   parameter RECORD_UTIL = 0,
   localparam NODES = X * Y
)(
   input                            clk_debug,
   input                            clk_noc,
   input                            rst_debug,
   input                            rst_noc,
   input                            start_rec,

   output [1:0]                     debug_ring_in_ready,
   input dii_flit [1:0]             debug_ring_in,
   output dii_flit [1:0]            debug_ring_out,
   input [1:0]                      debug_ring_out_ready,

   // Slot table config signals
   output [$clog2(MAX_PORTS+1)-1:0] lut_conf_data,
   output [$clog2(MAX_PORTS)-1:0]   lut_conf_sel,
   output [$clog2(LUT_SIZE)-1:0]    lut_conf_slot,
   output [$clog2(NODES)-1:0]       config_node,
   output                           lut_conf_valid,
   output                           lut_conf_valid_ni,
   output                           link_en_valid,    // Same interface is used to enable links for outgoing channels

   // Fault injection signals. These are dedicated enable signals for each link.
   // They are addressed in a [router][in_link] fashion, with the links from a
   // router to the NI as the highest indices.
   output [NODES-1:0][7:0]       fim_en,

   // Signals for detected errors from the corresponding FDMs.
   input [NODES-1:0][7:0]        faults,

   // Utilization signals
   input [NODES-1:0][7:0]        tdm_util,
   input [NODES-1:0][7:0]        be_util
);

   // DII signals from NCM to debug_ring_expand
   dii_flit    dii_in;
   logic       dii_in_ready;

   // DII signals from debug_ring_expand to NCM
   dii_flit    dii_out;
   logic       dii_out_ready;

   debug_ring_expand #(
      .BUFFER_SIZE   (4),
      .PORTS         (1))
   u_debug_ring_segment(
      .clk           (clk_debug),
      .rst           (rst_debug),
      .id_map        (16'(DEBUG_BASEID)),
      .dii_in        (dii_in),
      .dii_in_ready  (dii_in_ready),
      .dii_out       (dii_out),
      .dii_out_ready (dii_out_ready),
      .ext_in        (debug_ring_in),
      .ext_in_ready  (debug_ring_in_ready),
      .ext_out       (debug_ring_out),
      .ext_out_ready (debug_ring_out_ready)
   );

   noc_control_module #(
      .MAX_DI_PKT_LEN   (MAX_DI_PKT_LEN),
      .LUT_SIZE         (LUT_SIZE),
      .X                (X),
      .Y                (Y),
      .MAX_PORTS        (MAX_PORTS),
      .SIMPLE_NCM       (SIMPLE_NCM),
      .ENABLE_FDM_FIM   (ENABLE_FDM_FIM),
      .RECORD_UTIL      (RECORD_UTIL))
   u_noc_control_module (
      .clk_debug        (clk_debug),
      .clk_noc          (clk_noc),
      .rst_debug        (rst_debug),
      .rst_noc          (rst_noc),
      .start_rec        (start_rec),
      .debug_in         (dii_out),
      .debug_in_ready   (dii_out_ready),
      .debug_out        (dii_in),
      .debug_out_ready  (dii_in_ready),
      .id               (16'(DEBUG_BASEID)),
      .lut_conf_data    (lut_conf_data),
      .lut_conf_sel     (lut_conf_sel),
      .lut_conf_slot    (lut_conf_slot),
      .config_node      (config_node),
      .lut_conf_valid   (lut_conf_valid),
      .lut_conf_valid_ni(lut_conf_valid_ni),
      .link_en_valid    (link_en_valid),
      .fim_en           (fim_en),
      .faults           (faults),
      .tdm_util         (tdm_util),
      .be_util          (be_util)
   );

endmodule // noc_control_module_wrapper
