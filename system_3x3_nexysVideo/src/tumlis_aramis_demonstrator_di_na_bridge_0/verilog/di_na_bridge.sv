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
 * DI-NA bridge toplevel.
 * This is a debug module that allows to send data from the DI to the NoC
 * (ingress path) and forward data received over the NoC to the DI (egress
 * path).
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Stefan Keller <stefan.keller@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

import dii_package::dii_flit;

module di_na_bridge #(
   parameter TILEID                    = 'x,
   parameter INGRESS_BUFFER_SIZE       = 32, // Size of the ingress buffer in bytes
   parameter EGRESS_BUFFER_SIZE        = 32, // Size of the egress buffer in bytes
   parameter DI_FLIT_WIDTH             = 16,
   parameter NOC_FLIT_WIDTH            = 32,
   parameter NUM_BE_ENDPOINTS          = 2,
   parameter NUM_TDM_ENDPOINTS         = 2,
   parameter MAX_DI_PKT_LEN            = 12,
   parameter MAX_BE_PKT_LEN            = 10,
   parameter TDM_MAX_CHECKPOINT_DIST   = 10,
   parameter CT_LINKS                  = 2,
   parameter ENABLE_DR                 = 0,

   // Determines the size of the read path buffers
   localparam MAX_NOC_PKT_LEN          = MAX_BE_PKT_LEN > TDM_MAX_CHECKPOINT_DIST ? MAX_BE_PKT_LEN : TDM_MAX_CHECKPOINT_DIST,

   // Module specific registers
   localparam REG_TILEID               = 16'h200,
   localparam REG_MAX_DI_PKT_LEN       = 16'h201,
   localparam REG_NOC_FLIT_WIDTH       = 16'h202,
   localparam REG_NUM_LINKS            = 16'h203,
   localparam REG_NUM_BE_EP            = 16'h204,
   localparam REG_MAX_BE_PKT_LEN       = 16'h205,
   localparam REG_NUM_TDM_EP           = 16'h206,
   localparam REG_TDM_MAX_CHCKPNT_DIST = 16'h207,
   localparam REG_BE_ACT               = 16'h208,
   localparam REG_TDM_ACT              = 16'h209,
   localparam REG_DR_ENABLED           = 16'h20a
)(
   input             clk,
   input             rst_debug,
   input             rst_sys,

   input dii_flit    debug_in,
   output            debug_in_ready,
   output dii_flit   debug_out,
   input             debug_out_ready,

   input [15:0]      id,

   input             irq_tdm,
   input             irq_be,

   input                      wb_ack_i,
   input                      wb_err_i,
   input [NOC_FLIT_WIDTH-1:0] wb_dat_i,
   output [31:0]              wb_adr_o,
   output [31:0]              wb_dat_o,
   output [3:0]               wb_sel_o,
   output                     wb_cyc_o,
   output                     wb_stb_o,
   output                     wb_we_o
);

   dii_flit       ingress_flit;
   dii_flit       egress_flit;
   dii_flit       write_flit;
   wire           ingress_flit_ready;
   wire           egress_flit_ready;
   wire           write_flit_ready;

   wire [15:0]    event_dest;

   wire           req_write;
   wire           gnt_write;
   wire           req_read;
   wire           gnt_read;

   // DI payload flits to be send to host via packetizer
   wire [15:0]    out_flit_data;
   wire           out_flit_valid;
   wire           out_flit_last;
   wire           out_flit_ready;

   wire [31:0]    rd_wb_adr;
   wire           rd_wb_cyc;
   wire           rd_wb_stb;

   wire [31:0]    wr_wb_adr;
   wire [31:0]    wr_wb_dat;
   wire           wr_wb_cyc;
   wire           wr_wb_stb;
   wire           wr_wb_we;

   reg            req_tdm_active;
   reg            req_be_active;
   wire           tdm_active;
   wire           be_active;

   wire           reg_request;
   wire           reg_write;
   wire [15:0]    reg_addr;
   wire [1:0]     reg_size;
   wire [15:0]    reg_wdata;
   logic          reg_ack;
   logic          reg_err;
   logic [15:0]   reg_rdata;

   osd_regaccess_layer #(
      .MOD_VENDOR             (16'h4),
      .MOD_TYPE               (16'h4),
      .MOD_VERSION            (16'h0),
      .MAX_REG_SIZE           (16),
      .CAN_STALL              (0),
      .MOD_EVENT_DEST_DEFAULT (16'h0))
   u_io_regaccess(
      .clk              (clk),
      .rst              (rst_debug),
      .id               (id),
      .debug_in         (debug_in),
      .debug_in_ready   (debug_in_ready),
      .debug_out        (debug_out),
      .debug_out_ready  (debug_out_ready),
      .module_in        (egress_flit),
      .module_in_ready  (egress_flit_ready),
      .module_out       (ingress_flit),
      .module_out_ready (ingress_flit_ready),
      .stall            (),
      .event_dest       (event_dest),
      .reg_request      (reg_request), // output
      .reg_write        (reg_write),   // output
      .reg_addr         (reg_addr),    // output
      .reg_size         (reg_size),    // output
      .reg_wdata        (reg_wdata),   // output
      .reg_ack          (reg_ack),     // input
      .reg_err          (reg_err),     // input
      .reg_rdata        (reg_rdata)    // input
   );

   // Module specific registers
   always @(posedge clk) begin
      if (rst_debug | rst_sys) begin
         req_be_active <= 0;
         req_tdm_active <= 0;
      end else begin
         req_be_active <= (reg_request & reg_write & reg_addr == REG_BE_ACT) ? reg_wdata[0] : req_be_active;
         req_tdm_active <= (reg_request & reg_write & reg_addr == REG_TDM_ACT) ? reg_wdata[0] : req_tdm_active;
      end
   end

   always @(*) begin
      reg_ack = 1;
      reg_rdata = 0;
      reg_err = 0;

      if (reg_request & reg_write) begin
         if (reg_addr != REG_BE_ACT && reg_addr != REG_TDM_ACT) begin
            reg_err = 1;
         end
      end else begin
         case (reg_addr)
            REG_TILEID:                reg_rdata = 16'(TILEID);
            REG_MAX_DI_PKT_LEN:        reg_rdata = 16'(MAX_DI_PKT_LEN);
            REG_NOC_FLIT_WIDTH:        reg_rdata = 16'(NOC_FLIT_WIDTH);
            REG_NUM_LINKS:             reg_rdata = 16'(CT_LINKS);
            REG_NUM_BE_EP:             reg_rdata = 16'(NUM_BE_ENDPOINTS);
            REG_MAX_BE_PKT_LEN:        reg_rdata = 16'(MAX_BE_PKT_LEN);
            REG_NUM_TDM_EP:            reg_rdata = 16'(NUM_TDM_ENDPOINTS);
            REG_TDM_MAX_CHCKPNT_DIST:  reg_rdata = 16'(TDM_MAX_CHECKPOINT_DIST);
            REG_BE_ACT:                reg_rdata = 16'(be_active);
            REG_TDM_ACT:               reg_rdata = 16'(tdm_active);
            REG_DR_ENABLED:            reg_rdata = 16'(ENABLE_DR);
            default:                   reg_err = reg_request;
         endcase // case (reg_addr)
      end
   end // always @ (*)

   // Arbiter to schedule read and write operations on the bus.
   // Also activates and deactivates the endpoints.
   di_na_bridge_arbiter #(
      .NUM_BE_ENDPOINTS    (NUM_BE_ENDPOINTS),
      .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS))
   u_arbiter(
      .clk              (clk),
      .rst              (rst_sys),
      .req_rd           (req_read),
      .req_wr           (req_write),
      .req_be_active    (req_be_active),
      .req_tdm_active   (req_tdm_active),
      .rd_wb_adr_o      (rd_wb_adr),
      .rd_wb_cyc_o      (rd_wb_cyc),
      .rd_wb_stb_o      (rd_wb_stb),
      .wr_wb_adr_o      (wr_wb_adr),
      .wr_wb_dat_o      (wr_wb_dat),
      .wr_wb_cyc_o      (wr_wb_cyc),
      .wr_wb_stb_o      (wr_wb_stb),
      .wb_adr_o         (wb_adr_o),
      .wb_dat_o         (wb_dat_o),
      .wb_cyc_o         (wb_cyc_o),
      .wb_stb_o         (wb_stb_o),
      .wb_sel_o         (wb_sel_o),
      .wb_we_o          (wb_we_o),
      .gnt_rd           (gnt_read),
      .gnt_wr           (gnt_write),
      .be_active        (be_active),
      .tdm_active       (tdm_active)
   );

/*
 * **************************************************************
 * Egress path: NoC -> DI
 * **************************************************************
 */

   di_na_bridge_packetizer #(
      .MAX_PKT_LEN         (MAX_DI_PKT_LEN),
      .MAX_DATA_NUM_WORDS  ((MAX_NOC_PKT_LEN * 2) + 1))  // +1 for the endpoint information
   u_event_packetizer(
      .clk              (clk),
      .rst              (rst_debug),
      .debug_out        (egress_flit),
      .debug_out_ready  (egress_flit_ready),
      .id               (id),
      .dest             (event_dest),
      .out_flit_data    (out_flit_data),
      .out_flit_valid   (out_flit_valid),
      .out_flit_last    (out_flit_last),
      .out_flit_ready   (out_flit_ready)
   );

   na_read_wb #(
      .MAX_NOC_PKT_LEN     (MAX_NOC_PKT_LEN),
      .NOC_FLIT_WIDTH      (NOC_FLIT_WIDTH),
      .DI_FLIT_WIDTH       (DI_FLIT_WIDTH),
      .NUM_BE_ENDPOINTS    (NUM_BE_ENDPOINTS),
      .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS),
      .EGRESS_BUFFER_SIZE  (EGRESS_BUFFER_SIZE))
   u_na_read_wb (
      .clk              (clk),
      .rst_debug        (rst_debug),
      .rst_sys          (rst_sys),
      .irq_tdm          (irq_tdm),
      .irq_be           (irq_be),
      .enable           (gnt_read),
      .req              (req_read),
      .wb_dat_i         (wb_dat_i),
      .wb_ack_i         (wb_ack_i),
      .wb_err_i         (wb_err_i),
      .wb_adr_o         (rd_wb_adr),
      .wb_cyc_o         (rd_wb_cyc),
      .wb_stb_o         (rd_wb_stb),
      .out_flit_data    (out_flit_data),
      .out_flit_valid   (out_flit_valid),
      .out_flit_last    (out_flit_last),
      .out_flit_ready   (out_flit_ready)
   );

/*
 * **************************************************************
 * Ingress path: DI -> NoC
 * **************************************************************
 */

   discard_header
   u_discard_header(
      .clk        (clk),
      .rst        (rst_sys),
      .in_flit    (ingress_flit),
      .in_ready   (ingress_flit_ready),
      .out_flit   (write_flit),
      .out_ready  (write_flit_ready)
   );

   na_write_wb #(
      .NOC_FLIT_WIDTH      (NOC_FLIT_WIDTH),
      .DI_FLIT_WIDTH       (DI_FLIT_WIDTH),
      .MAX_DI_PKT_LEN      (MAX_DI_PKT_LEN),
      .MAX_NOC_PKT_LEN     (MAX_NOC_PKT_LEN),
      .NUM_BE_ENDPOINTS    (NUM_BE_ENDPOINTS),
      .NUM_TDM_ENDPOINTS   (NUM_TDM_ENDPOINTS),
      .INGRESS_BUFFER_SIZE (INGRESS_BUFFER_SIZE))
   u_na_write_wb(
      .clk           (clk),
      .rst           (rst_sys),
      .enable        (gnt_write),
      .req           (req_write),
      .in_flit       (write_flit),
      .in_flit_ready (write_flit_ready),
      .wb_err_i      (wb_err_i),
      .wb_ack_i      (wb_ack_i),
      .wb_adr_o      (wr_wb_adr),
      .wb_dat_o      (wr_wb_dat),
      .wb_stb_o      (wr_wb_stb),
      .wb_cyc_o      (wr_wb_cyc)
   );

endmodule
