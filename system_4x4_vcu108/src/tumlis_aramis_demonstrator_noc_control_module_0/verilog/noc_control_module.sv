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
 * NoC control module for the ARAMiS II demonstrator.
 * This is a debug module that communicates with the host PC via the debug
 * interconnect. It sets up the slot tables of the routers and NIs in the NoC,
 * injects faults on selected links, informs the host about detected errors, and
 * sends statistics about the link utilization to the host PC.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Laura Grünauer
 */

import dii_package::dii_flit;

module noc_control_module #(
   parameter MAX_DI_PKT_LEN = 12,
   parameter LUT_SIZE = 8,
   parameter X = 3,
   parameter Y = 3,
   parameter MAX_PORTS = 6,
   parameter SIMPLE_NCM = 0,
   parameter ENABLE_FDM_FIM = 1,
   parameter RECORD_UTIL = 0, // use the record version of the util module instead of the continuous one
   localparam NODES = X * Y
)(
   input             clk_debug,
   input             clk_noc,
   input             rst_debug,
   input             rst_noc,
   input             start_rec,

   input             dii_flit debug_in, output debug_in_ready,
   output            dii_flit debug_out, input debug_out_ready,

   input [15:0]      id,

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

   wire           stall;
   wire [15:0]    event_dest;

   wire           module_in_ready;
   dii_flit       module_in;

   wire           fd_out_ready;
   dii_flit       fd_module_out;

   wire           util_out_ready;
   dii_flit       util_module_out;

   wire           module_out_ready;
   dii_flit       module_out;

   wire           in_cdc_full;
   wire           in_cdc_empty;
   wire           in_cdc_out_ready;
   dii_flit       in_cdc_out;

   wire           out_cdc_full;
   wire           out_cdc_empty;
   dii_flit       out_cdc_in;

   // to connect discard header and FI/lut config module
   dii_flit       dh_out_flit;
   dii_flit       fi_flit;
   reg            fi_flit_valid;
   logic          nxt_fi_flit_valid;
   dii_flit       lut_flit;
   reg            lut_flit_valid;
   logic          nxt_lut_flit_valid;
   // to set clk count for util cont module
   dii_flit       clk_flit;
   reg            clk_flit_valid;
   logic          nxt_clk_flit_valid;

   // register access signals
   logic          reg_request;
   logic [15:0]   reg_addr;
   logic          reg_ack;
   logic          reg_err;
   logic [15:0]   reg_rdata;

   enum {IDLE, FD_OUT, UTIL_OUT} state, nxt_state;

   // Configurable max clock counter value
   // Util data is sent out when clk_counter reaches max_clk_counter (if
   // max_clk_counter is > 0)
   reg [31:0]  max_clk_counter;
   reg [15:0]  max_cnt_low_word;
   reg         set_max_cnt_high_word;
   wire        cnt_stall;
   assign cnt_stall = ~|max_clk_counter;

   // CDC for debug reset
   wire                                rst_dbg;
   (* ASYNC_REG = "true" *) reg [1:0]  rst_dbg_cdc;
   always_ff @(posedge clk_noc) begin
      {rst_dbg_cdc[1], rst_dbg_cdc[0]} <= {rst_dbg_cdc[0], rst_dbg};
   end
   assign rst_dbg = rst_dbg_cdc[1];


   osd_regaccess_layer #(
      .MOD_VENDOR(16'h4), .MOD_TYPE(16'h5), .MOD_VERSION(16'h0),
      .MAX_REG_SIZE(16), .CAN_STALL(1), .MOD_EVENT_DEST_DEFAULT(16'h0))
   u_regaccess(
      .clk              (clk_debug),
      .rst              (rst_debug),
      .id               (id),
      .debug_in         (debug_in),
      .debug_in_ready   (debug_in_ready),
      .debug_out        (debug_out),
      .debug_out_ready  (debug_out_ready),
      .module_in        (module_in),
      .module_in_ready  (module_in_ready),
      .module_out       (module_out),
      .module_out_ready (module_out_ready),
      .stall            (stall),
      .event_dest       (event_dest),
      .reg_request      (reg_request),
      .reg_write        (),
      .reg_addr         (reg_addr),
      .reg_size         (),
      .reg_wdata        (),
      .reg_ack          (reg_ack),
      .reg_err          (reg_err),
      .reg_rdata        (reg_rdata)
   );

   // Module specific registers
   always @(*) begin
      reg_ack = 1;
      reg_rdata = 0;
      reg_err = 0;

      case (reg_addr)
         16'h200: reg_rdata = 16'(LUT_SIZE);
         16'h201: reg_rdata = {8'(Y), 8'(X)};
         16'h202: reg_rdata = max_clk_counter[15:0];
         16'h203: reg_rdata = max_clk_counter[31:16];
         16'h204: reg_rdata = 16'(MAX_PORTS);
         16'h205: reg_rdata = 16'(SIMPLE_NCM);
         default: reg_err = reg_request;
      endcase // case (reg_addr)
   end // always @ (*)

   // --------------------------------------------------------------------------
   // Receiving modules

   assign module_out_ready = ~in_cdc_full;
   // Cross into NoC clock domain
   fifo_dualclock_fwft #(
      .WIDTH(17),
      .DEPTH(16))
   u_cdc_in (
      .wr_clk     (clk_debug),
      .wr_rst     (rst_debug),
      .wr_en      (module_out.valid),
      .din        ({module_out.last, module_out.data}),

      .rd_clk     (clk_noc),
      .rd_rst     (rst_dbg),
      .rd_en      (in_cdc_out_ready),
      .dout       ({in_cdc_out.last, in_cdc_out.data}),

      .full       (in_cdc_full),
      .prog_full  (),
      .empty      (in_cdc_empty),
      .prog_empty ()
   );

   assign in_cdc_out.valid = ~in_cdc_empty;

   // discard_header module
   discard_header
   u_discard_header (
      .clk        (clk_noc),
      .rst        (rst_dbg),
      .in_flit    (in_cdc_out),
      .in_ready   (in_cdc_out_ready),
      .out_flit   (dh_out_flit),
      .out_ready  (1'b1)
   );

   generate
      if (SIMPLE_NCM == 1 || ENABLE_FDM_FIM == 0) begin
         assign fim_en = 0;
      end else begin
         // FI_module
         noc_control_module_FI #(
            .X(X), .Y(Y))
         u_fault_injection(
            .clk     (clk_noc),
            .rst     (rst_noc),
            .flit_in (fi_flit),
            .fim_en  (fim_en)
         );
      end
   endgenerate

   // Slot table config module
   noc_control_module_lut_conf #(
      .X(X),
      .Y(Y),
      .MAX_PORTS(MAX_PORTS),
      .LUT_SIZE(LUT_SIZE))
   u_lut_config(
      .clk              (clk_noc),
      .rst              (rst_noc),
      .flit_in          (lut_flit),
      .lut_conf_data    (lut_conf_data),
      .lut_conf_sel     (lut_conf_sel),
      .lut_conf_slot    (lut_conf_slot),
      .config_node      (config_node),
      .lut_conf_valid   (lut_conf_valid),
      .lut_conf_valid_ni(lut_conf_valid_ni),
      .link_en_valid    (link_en_valid)
   );

   assign fi_flit = fi_flit_valid ? dh_out_flit : 0;
   assign lut_flit = lut_flit_valid ? dh_out_flit : 0;
   assign clk_flit = clk_flit_valid ? dh_out_flit : 0;

   // Select target for incoming flits.
   always_ff @(posedge clk_noc) begin
      if (rst_dbg) begin
         fi_flit_valid <= 1'b0;
         lut_flit_valid <= 1'b0;
         clk_flit_valid <= 1'b0;
      end else begin
         fi_flit_valid <= nxt_fi_flit_valid;
         lut_flit_valid <= nxt_lut_flit_valid;
         clk_flit_valid <= nxt_clk_flit_valid;
      end
   end

   always_comb begin
      nxt_fi_flit_valid = fi_flit_valid;
      nxt_lut_flit_valid = lut_flit_valid;
      nxt_clk_flit_valid = clk_flit_valid;
      if (dh_out_flit.valid == 1) begin
         if (fi_flit_valid == 0 && lut_flit_valid == 0 && clk_flit_valid == 0) begin
            // Forward to fault injection sub-module
            if (dh_out_flit.data == 0) begin
               nxt_fi_flit_valid = 1'b1;
            // Forward to LUT config sub-module
            end else if (dh_out_flit.data == 1) begin
               nxt_lut_flit_valid = 1'b1;
            end else if (dh_out_flit.data == 2) begin
               nxt_clk_flit_valid = 1'b1;
            end
         end else begin
            if (dh_out_flit.last == 1) begin
               nxt_fi_flit_valid = 1'b0;
               nxt_lut_flit_valid = 1'b0;
               nxt_clk_flit_valid = 1'b0;
            end
         end
      end
   end

   // Set max_clk_counter
   always_ff @(posedge clk_noc) begin
      if (rst_dbg) begin
         max_clk_counter <= 0;
         set_max_cnt_high_word <= 1'b0;
      end else begin
         if (clk_flit.valid) begin
            if (~set_max_cnt_high_word) begin
               max_cnt_low_word <= clk_flit.data;
               set_max_cnt_high_word <= 1'b1;
            end else if(clk_flit.last) begin
               max_clk_counter <= {clk_flit.data, max_cnt_low_word};
               set_max_cnt_high_word <= 1'b0;
            end
         end
      end
   end


   // --------------------------------------------------------------------------
   // Sending modules

   generate
      if (SIMPLE_NCM && RECORD_UTIL == 0) begin
         assign module_in.last = 0;
         assign module_in.data = 0;
         assign module_in.valid = 0;
      end else begin
         if (ENABLE_FDM_FIM) begin
            // FD_module
            noc_control_module_FD #(
               .MAX_DI_PKT_LEN(MAX_DI_PKT_LEN),
               .X(X), .Y(Y))
            u_fault_detection(
               .clk              (clk_noc),
               .rst_noc          (rst_noc),
               .rst_debug        (rst_dbg),
               .stall            (stall | cnt_stall),
               .id               (id),
               .max_clk_counter  (max_clk_counter),
               .fd_out_ready     (fd_out_ready),
               .event_dest       (event_dest),
               .faults_in        (faults),
               .faults_out       (fd_module_out)
            );
            assign fd_out_ready = (state == FD_OUT) ? ~out_cdc_full : 0;
         end else begin
            assign fd_module_out.valid = 0;
            assign fd_module_out.data = 0;
            assign fd_module_out.last = 0;
            assign fd_out_ready = 0;
         end

         // Util_module
         if (RECORD_UTIL) begin
            noc_control_module_util_rec #(
               .MAX_DI_PKT_LEN(MAX_DI_PKT_LEN),
               .X(X), .Y(Y))
            u_utilization(
               .clk              (clk_noc),
               .rst              (rst_noc | stall),
               .start_rec        (start_rec),
               .id               (id),
               .util_out_ready   (util_out_ready),
               .event_dest       (event_dest),
               .tdm_util         (tdm_util),
               .be_util          (be_util),
               .util_out         (util_module_out)
            );
         end else begin
            noc_control_module_util_cont #(
               .MAX_DI_PKT_LEN(MAX_DI_PKT_LEN),
               .X(X), .Y(Y))
            u_utilization(
               .clk              (clk_noc),
               .rst_noc          (rst_noc),
               .rst_debug        (rst_dbg),
               .stall            (stall | cnt_stall),
               .id               (id),
               .max_clk_counter  (max_clk_counter),
               .util_out_ready   (util_out_ready),
               .event_dest       (event_dest),
               .tdm_util         (tdm_util),
               .be_util          (be_util),
               .util_out         (util_module_out)
            );
         end
         assign util_out_ready = (state == UTIL_OUT) ? ~out_cdc_full : 0;

         assign out_cdc_in = (state == UTIL_OUT) ? util_module_out : (state == FD_OUT) ? fd_module_out : 0;

         // Cross into debug ring clock domain
         fifo_dualclock_fwft #(
            .WIDTH(17),
            .DEPTH(16))
         u_cdc_out (
            .wr_clk     (clk_noc),
            .wr_rst     (rst_dbg),
            .wr_en      (out_cdc_in.valid),
            .din        ({out_cdc_in.last, out_cdc_in.data}),

            .rd_clk     (clk_debug),
            .rd_rst     (rst_debug),
            .rd_en      (module_in_ready),
            .dout       ({module_in.last, module_in.data}),

            .full       (out_cdc_full),
            .prog_full  (),
            .empty      (out_cdc_empty),
            .prog_empty ()
         );

         assign module_in.valid = ~out_cdc_empty;

         // FSM to send out utilization or faults when they are ready, with priority
         // for faults
         always_ff @(posedge clk_noc) begin
            if (rst_dbg) begin
               state <= IDLE;
            end else begin
               state <= nxt_state;
            end
         end

         always_comb begin
            nxt_state = state;

            case(state)
               IDLE: begin
                  if (fd_module_out.valid) begin
                     nxt_state = FD_OUT;
                  end else if (util_module_out.valid) begin
                     nxt_state = UTIL_OUT;
                  end
               end
               FD_OUT: begin
                  if (fd_module_out.last & fd_out_ready) begin
                     if (util_module_out.valid) begin
                        nxt_state = UTIL_OUT;
                     end else begin
                        nxt_state = IDLE;
                     end
                  end
               end
               UTIL_OUT: begin
                  if (util_module_out.last & util_out_ready) begin
                     nxt_state = IDLE;
                  end
               end
            endcase
         end
      end
   endgenerate

endmodule // noc_control_module
