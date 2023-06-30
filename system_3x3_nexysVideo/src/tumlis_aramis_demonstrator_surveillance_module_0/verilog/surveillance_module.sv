/* Copyright (c) 2020-2021 by the author(s)
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
 * Sniffs on received and sent packets to collect statistics from and to where
 * packets were sent. Generates a debug event every set number of clk cycles
 * which contains the collected information. The format is as follows:
 * {Debug event header}         this is given by osd
 * ({num_packets from/to tile/channel idx word 0}) (only if word == 0)
 * {num_packets from/to tile/channel idx word 1}
 * {num_packets from/to tile/channel idx+1 word 0}
 * {num_packets from/to tile/channel idx+1 word 1}
 * for more details, see sm_collect_event
 *
 * Additionally this module provides the functionality to configure the cores.
 * The registers can be configured with debug packets. The core is notified with
 * an irq when the content is changed. These changed register can then be read
 * by the core. First the core reads from address 0x000 to get the address of
 * a changed registers and then gets the value from that address.
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 */


import dii_package::dii_flit;

module surveillance_module #(
   parameter MAX_LEN = 8,
   parameter NUM_TDM_ENDPOINTS = 4,
   parameter NUM_TILES = 9,
   parameter MAX_DI_PKT_LEN= 12,
   parameter ID = 'x,
   localparam MAX_REG_SIZE = 32
)(
   input clk,
   input rst_dbg,
   input rst_sys,

   // wires between wb and na
   input [31:0]      wb_na_addr,
   input [31:0]      wb_na_data_in,    // sent data
   input [31:0]      wb_na_data_out,   // received data
   input             wb_na_we,
   input             wb_na_cyc,
   input             wb_na_stb,
   input             wb_na_ack,

   // debug i/o
   input dii_flit    debug_in,
   output            debug_in_ready,
   output dii_flit   debug_out,
   input             debug_out_ready,

   // ports to wb
   input [31:0]      wb_addr,
   input             wb_cyc,
   input [31:0]      wb_data_in,
   input [3:0]       wb_sel,     // unused
   input             wb_stb,
   input             wb_we,
   input             wb_cab,     // unused
   input [2:0]       wb_cti,     // unused
   input [1:0]       wb_bte,     // unused
   output            wb_ack,
   output            wb_rty,     // unused
   output            wb_err,
   output [31:0]     wb_data_out,

   output            irq,
   input [15:0]      id
);
   localparam TILE_WIDTH = $clog2(NUM_TILES);
   localparam ENDP_WIDTH = $clog2(NUM_TDM_ENDPOINTS);

   // between sm_input_decode and sm_tdm/be_send/recv
   wire [3:0]              enable;
   wire [31:0]             data;
   wire [ENDP_WIDTH-1:0]   ep;

   // between sm_tdm/be_send/recv and sm_collect_event
   wire [TILE_WIDTH-1:0]   dest_be;
   wire [TILE_WIDTH-1:0]   src_be;
   wire [ENDP_WIDTH-1:0]   dest_tdm;
   wire [ENDP_WIDTH-1:0]   src_tdm;
   wire                    valid_be_send;
   wire                    valid_be_recv;
   wire                    valid_tdm_send;
   wire                    valid_tdm_recv;
   wire                    faulty_be_recv;

   // between sm_collect_event and osd_regaccess_layer
   dii_flit    module_in;
   wire        module_in_ready;
   wire [15:0] event_dest;

   // between osd_regaccess_layer and discard_header
   dii_flit    module_out;
   wire        module_out_ready;

   // between discard_header and sm_config
   dii_flit    dh_out_flit;

   // between sm_config and sm_collect_event
   wire [31:0] max_clk_counter;

   // register access signals
   logic          reg_request;
   logic [15:0]   reg_addr;
   logic          reg_ack;
   logic          reg_err;
   logic [15:0]   reg_rdata;


   osd_regaccess_layer #(
         .MOD_VENDOR             (16'h4),
         .MOD_TYPE               (16'h6),
         .MOD_VERSION            (16'h0),
         .MOD_EVENT_DEST_DEFAULT (16'h0),
         .CAN_STALL              (0),
         .MAX_REG_SIZE           (MAX_REG_SIZE))
      u_regaccess(
         .clk    (clk),
         .rst    (rst_dbg),
         .id     (id),

         .debug_in         (debug_in),
         .debug_in_ready   (debug_in_ready),
         .debug_out        (debug_out),
         .debug_out_ready  (debug_out_ready),
         .module_in        (module_in),
         .module_in_ready  (module_in_ready),
         .module_out       (module_out),
         .module_out_ready (module_out_ready),
         .stall            (),
         .event_dest       (event_dest),
         .reg_request      (reg_request), // output
         .reg_write        (),            // output, not used
         .reg_addr         (reg_addr),    // output
         .reg_size         (),            // output, not used
         .reg_wdata        (),            // output, not used
         .reg_ack          (reg_ack),     // input
         .reg_err          (reg_err),     // input
         .reg_rdata        (reg_rdata)    // input
      );

   // Module specific registers
   always @(*) begin
      reg_ack = 1;
      reg_rdata = 0;
      reg_err = 0;

      case (reg_addr)
         16'h200: reg_rdata = 16'(NUM_TDM_ENDPOINTS);
         default: reg_err = reg_request;
      endcase // case (reg_addr)
   end // always @ (*)

   // discard_header module
   discard_header
      u_discard_header (
         .clk         (clk),
         .rst         (rst_dbg),
         .in_flit     (module_out),
         .in_ready    (module_out_ready),
         .out_flit    (dh_out_flit),
         .out_ready   (1'b1)
      );

   sm_config #(
         .NUM_TILES        (NUM_TILES))
      u_config(
         .clk              (clk),
         .rst              (rst_sys),

         .dii_flit_in      (dh_out_flit),

         .wb_addr          (wb_addr),
         .wb_cyc           (wb_cyc),
         .wb_data_in       (wb_data_in),
         .wb_sel           (wb_sel),
         .wb_stb           (wb_stb),
         .wb_we            (wb_we),
         .wb_cab           (wb_cab),
         .wb_cti           (wb_cti),
         .wb_bte           (wb_bte),
         .wb_ack           (wb_ack),
         .wb_rty           (wb_rty),
         .wb_err           (wb_err),
         .wb_data_out      (wb_data_out),

         .max_clk_counter  (max_clk_counter),
         .irq              (irq)
      );

   sm_input_decode #(
         .NUM_TDM_ENDPOINTS(NUM_TDM_ENDPOINTS))
      u_input_decode(
         .clk              (clk),
         .rst              (rst_sys),
         .wb_na_addr       (wb_na_addr),
         .wb_na_data_in    (wb_na_data_in),    // sent data
         .wb_na_data_out   (wb_na_data_out),   // received data
         .wb_na_we         (wb_na_we),
         .wb_na_cyc        (wb_na_cyc),
         .wb_na_stb        (wb_na_stb),
         .wb_na_ack        (wb_na_ack),
         .enable           (enable),
         .data             (data),
         .ep               (ep)
      );

   sm_be_send #(
         .MAX_LEN    (MAX_LEN),
         .NUM_TILES  (NUM_TILES))
      u_be_send(
         .clk        (clk),
         .rst        (rst_sys),

         .enable     (enable[0]),
         .data       (data),
         .dest       (dest_be),
         .valid      (valid_be_send)
      );

   sm_be_receive #(
         .MAX_LEN    (MAX_LEN),
         .TILEID     (ID),
         .NUM_TILES  (NUM_TILES))
      u_be_receive(
         .clk        (clk),
         .rst        (rst_sys),

         .enable     (enable[1]),
         .data       (data),
         .src        (src_be),
         .valid      (valid_be_recv),
         .faulty     (faulty_be_recv)
      );

   sm_tdm_send #(
         .MAX_LEN             (MAX_LEN),
         .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS))
      u_tdm_send(
         .clk     (clk),
         .rst     (rst_sys),

         .enable  (enable[2]),
         .data    (data),
         .ep      (ep),
         .dest    (dest_tdm),
         .valid   (valid_tdm_send)
      );

   sm_tdm_receive #(
         .MAX_LEN             (MAX_LEN),
         .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS))
      u_tdm_receive(
         .clk     (clk),
         .rst     (rst_sys),

         .enable  (enable[3]),
         .data    (data),
         .ep      (ep),
         .src     (src_tdm),
         .valid   (valid_tdm_recv)
      );

   sm_collect_event #(
         .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS),
         .NUM_TILES           (NUM_TILES),
         .TILEID              (ID),
         .MAX_DI_PKT_LEN      (MAX_DI_PKT_LEN))
      u_collect_event(
         .clk                 (clk),
         .rst_dbg             (rst_dbg),
         .rst_sys             (rst_sys),

         .id                  (id),
         .event_dest          (event_dest),

         .dii_out_flit        (module_in),
         .dii_out_flit_ready  (module_in_ready),

         .dest_be             (dest_be),
         .src_be              (src_be),
         .dest_tdm            (dest_tdm),
         .src_tdm             (src_tdm),
         .valid_be_send       (valid_be_send),
         .valid_be_recv       (valid_be_recv),
         .valid_tdm_send      (valid_tdm_send),
         .valid_tdm_recv      (valid_tdm_recv),
         .faulty              (faulty_be_recv),

         .max_clk_counter     (max_clk_counter)
      );

endmodule // surveillance_module
