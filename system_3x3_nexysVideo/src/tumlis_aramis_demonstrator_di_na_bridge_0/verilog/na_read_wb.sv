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
 * The module reads data from the network adapter and breaks them into 16-bit
 * packets which are then buffered and forwarded to the packetizer.
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Stefan Keller <stefan.keller@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module na_read_wb #(
   parameter MAX_NOC_PKT_LEN        = 10,
   parameter DI_FLIT_WIDTH          = 16,
   parameter NOC_FLIT_WIDTH         = 32,
   parameter NUM_BE_ENDPOINTS       = 1,
   parameter NUM_TDM_ENDPOINTS      = 1,
   parameter EGRESS_BUFFER_SIZE     = 32, // Buffer size in bytes

   localparam EGRESS_BUFFER_DEPTH   = 1 << $clog2(EGRESS_BUFFER_SIZE / 2)  // 16 bit wide buffer
)(
   input                      clk,
   input                      rst_debug,
   input                      rst_sys,
   input                      irq_tdm,
   input                      irq_be,
   input                      enable,
   output                     req,

   output [31:0]              wb_adr_o,
   output                     wb_cyc_o,
   output                     wb_stb_o,
   input [NOC_FLIT_WIDTH-1:0] wb_dat_i,
   input                      wb_ack_i,
   input                      wb_err_i,

   // Signals from/to packetizer
   output [DI_FLIT_WIDTH-1:0] out_flit_data,
   output                     out_flit_valid,
   output                     out_flit_last,
   input                      out_flit_ready
);
   // Signals between read FSM and 32_to_16_bit_flit_buffer
   wire [NOC_FLIT_WIDTH-1:0]  in_flit_data;
   wire                       in_flit_valid;
   wire                       in_flit_last;
   wire                       in_flit_16;

   // Signals between 32_to_16_bit_flit_buffer and egress buffer
   wire [DI_FLIT_WIDTH-1:0]   buf_flit_data;
   wire                       buf_flit_valid;
   wire                       buf_flit_last;
   wire                       buf_flit_ready;

   fsm_na_read #(
      .MAX_NOC_PKT_LEN     (MAX_NOC_PKT_LEN),
      .NOC_FLIT_WIDTH      (NOC_FLIT_WIDTH),
      .NUM_BE_ENDPOINTS    (NUM_BE_ENDPOINTS),
      .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS))
   u_fsm_na_read(
      .clk              (clk),
      .rst_debug        (rst_debug),
      .rst_sys          (rst_sys),
      .irq_tdm          (irq_tdm),
      .irq_be           (irq_be),
      .wb_ack_i         (wb_ack_i),
      .wb_dat_i         (wb_dat_i),
      .wb_err_i         (wb_err_i),
      .enable           (enable),

      .wb_adr_o         (wb_adr_o),
      .wb_cyc_o         (wb_cyc_o),
      .wb_stb_o         (wb_stb_o),

      // Signals from/to flit buffer (32 to 16 bit)
      .out_flit_data    (in_flit_data),
      .out_flit_valid   (in_flit_valid),
      .out_flit_last    (in_flit_last),
      .out_flit_16      (in_flit_16),
      .req              (req),
      .buffer_empty     (~buf_flit_valid)
   );

   flit_buffer_32_to_16_bit #(
      .MAX_PKT_LEN      (MAX_NOC_PKT_LEN))
   u_flit_buffer_32_to_16_bit(
      .clk              (clk),
      .rst              (rst_debug),
      .in_flit_data     (in_flit_data),
      .in_flit_valid    (in_flit_valid),
      .in_flit_last     (in_flit_last),
      .in_flit_16       (in_flit_16),

      .out_flit_data    (buf_flit_data),
      .out_flit_valid   (buf_flit_valid),
      .out_flit_last    (buf_flit_last),
      .out_flit_ready   (buf_flit_ready)
   );

   noc_buffer #(
      .FLIT_WIDTH (DI_FLIT_WIDTH),
      .DEPTH      (EGRESS_BUFFER_DEPTH))
   u_egress_buffer(
      .clk        (clk),
      .rst        (rst_debug),
      .in_flit    (buf_flit_data),
      .in_valid   (buf_flit_valid),
      .in_last    (buf_flit_last),
      .in_ready   (buf_flit_ready),
      .out_flit   (out_flit_data),
      .out_valid  (out_flit_valid),
      .out_last   (out_flit_last),
      .out_ready  (out_flit_ready)
   );

endmodule
