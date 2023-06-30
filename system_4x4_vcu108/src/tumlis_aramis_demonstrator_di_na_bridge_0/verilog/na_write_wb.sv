/* Copyright (c) 2019 by the author(s)
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
 * The module transforms 16-bit flits from the DI into 32-bit flits for the NoC.
 * It passes the incoming data to its corresponding endpoint in the NI.
 * 
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 */

import dii_package::dii_flit;

module na_write_wb #(
   parameter NOC_FLIT_WIDTH         = 32,
   parameter DI_FLIT_WIDTH          = 16,
   parameter MAX_DI_PKT_LEN         = 12,
   parameter MAX_NOC_PKT_LEN        = 10,
   parameter NUM_BE_ENDPOINTS       = 1,
   parameter NUM_TDM_ENDPOINTS      = 1,
   parameter INGRESS_BUFFER_SIZE    = 32, // Buffer size in bytes

   localparam INGRESS_BUFFER_DEPTH  = 1 << $clog2(INGRESS_BUFFER_SIZE / 4),   // 32 bit wide buffer
   localparam PKT_BUFFER_DEPTH      = 1 << $clog2(MAX_NOC_PKT_LEN + 1)        // +1 for the first 'flit' selecting the EP
)(
   input                            clk,
   input                            rst,
   input                            enable,
   output                           req,

   input dii_flit                   in_flit,
   output                           in_flit_ready,

   input                            wb_err_i,
   input                            wb_ack_i,
   output [31:0]                    wb_adr_o,
   output [NOC_FLIT_WIDTH-1:0]      wb_dat_o,
   output                           wb_stb_o,
   output                           wb_cyc_o
);

   wire [NOC_FLIT_WIDTH-1:0]           buff_in_flit_data;
   wire                                buff_in_flit_valid;
   wire                                buff_in_flit_last;
   wire                                buff_in_flit_ready;

   wire [NOC_FLIT_WIDTH-1:0]           buff_out_flit_data;
   wire                                buff_out_flit_valid;
   wire                                buff_out_flit_last;
   wire                                buff_out_flit_ready;

   wire [NOC_FLIT_WIDTH-1:0]           ingress_flit_data;
   wire                                ingress_flit_valid;
   wire                                ingress_flit_last;
   wire                                ingress_flit_ready;
   wire [$clog2(PKT_BUFFER_DEPTH):0]   packet_size;

   di_to_noc_buffer
   u_di_to_noc_flit_buffer(
      .clk              (clk),
      .rst              (rst),
      .in_flit          (in_flit),
      .in_flit_ready    (in_flit_ready),
      .out_flit_data    (buff_in_flit_data),
      .out_flit_valid   (buff_in_flit_valid),
      .out_flit_last    (buff_in_flit_last),
      .out_flit_ready   (buff_in_flit_ready)
   );

   noc_buffer #(
      .FLIT_WIDTH (NOC_FLIT_WIDTH),
      .DEPTH      (INGRESS_BUFFER_DEPTH))
   u_ingress_buffer(
      .clk        (clk),
      .rst        (rst),
      .in_flit    (buff_in_flit_data),
      .in_valid   (buff_in_flit_valid),
      .in_last    (buff_in_flit_last),
      .in_ready   (buff_in_flit_ready),
      .out_flit   (buff_out_flit_data),
      .out_valid  (buff_out_flit_valid),
      .out_last   (buff_out_flit_last),
      .out_ready  (buff_out_flit_ready)
   );

   noc_buffer #(
      .FLIT_WIDTH (NOC_FLIT_WIDTH),
      .DEPTH      (PKT_BUFFER_DEPTH),
      .FULLPACKET (1))
   u_pkt_buffer(
      .clk           (clk),
      .rst           (rst),
      .in_flit       (buff_out_flit_data),
      .in_valid      (buff_out_flit_valid),
      .in_last       (buff_out_flit_last),
      .in_ready      (buff_out_flit_ready),
      .out_flit      (ingress_flit_data),
      .out_valid     (ingress_flit_valid),
      .out_last      (ingress_flit_last),
      .out_ready     (ingress_flit_ready),
      .packet_size   (packet_size)
   );

   gen_wb_write #(
      .NUM_BE_ENDPOINTS    (NUM_BE_ENDPOINTS),
      .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS),
      .NOC_FLIT_WIDTH      (NOC_FLIT_WIDTH))
   u_gen_wb_write(
      .clk           (clk),
      .rst           (rst),
      .enable        (enable),
      .req           (req),
      .packet_size   (packet_size),
      .in_flit_data  (ingress_flit_data),
      .in_flit_valid (ingress_flit_valid),
      .in_flit_last  (ingress_flit_last),
      .in_flit_ready (ingress_flit_ready),
      .wb_err_i      (wb_err_i),
      .wb_ack_i      (wb_ack_i),
      .wb_adr_o      (wb_adr_o),
      .wb_dat_o      (wb_dat_o),
      .wb_stb_o      (wb_stb_o),
      .wb_cyc_o      (wb_cyc_o)
   );

endmodule
