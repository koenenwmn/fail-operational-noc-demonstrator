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
 * This module configures the slot tables of the hybrid NoC.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *
 */


import dii_package::dii_flit;

module noc_control_module_lut_conf #(
   parameter   X = 3,
   parameter   Y = 3,
   parameter   LUT_SIZE = 8,
   parameter   MAX_PORTS = 6,
   localparam  NODES = X*Y
)(
   input                            clk, rst,
   input dii_flit                   flit_in,

   output [$clog2(MAX_PORTS+1)-1:0] lut_conf_data,
   output [$clog2(MAX_PORTS)-1:0]   lut_conf_sel,
   output [$clog2(LUT_SIZE)-1:0]    lut_conf_slot,
   output logic [$clog2(NODES)-1:0] config_node,
   output logic                     lut_conf_valid,
   output logic                     lut_conf_valid_ni,
   output logic                     link_en_valid  // Same interface is used to enable links for outgoing channels
);

   reg [$clog2(MAX_PORTS+1)-1:0]    reg_conf_data;
   logic [$clog2(MAX_PORTS+1)-1:0]  nxt_conf_data;
   reg [$clog2(MAX_PORTS)-1:0]      reg_conf_sel;
   logic [$clog2(MAX_PORTS)-1:0]    nxt_conf_sel;
   reg [$clog2(LUT_SIZE)-1:0]       reg_conf_slot;
   logic [$clog2(LUT_SIZE)-1:0]     nxt_conf_slot;

   assign lut_conf_data = reg_conf_data;
   assign lut_conf_sel = reg_conf_sel;
   assign lut_conf_slot = reg_conf_slot;

   wire ni_sel;
   wire link_en;
   wire [13:0] node_sel;
   assign ni_sel = flit_in.data[15];
   assign link_en = flit_in.data[14];
   assign node_sel = flit_in.data[13:0];

   reg set_valid;
   logic nxt_set_valid;

   always_ff @(posedge clk) begin
      if(rst) begin
         reg_conf_data <= 0;
         reg_conf_sel <= 0;
         reg_conf_slot <= 0;
         set_valid <= 0;
      end else begin
         reg_conf_data <= nxt_conf_data;
         reg_conf_sel <= nxt_conf_sel;
         reg_conf_slot <= nxt_conf_slot;
         set_valid <= nxt_set_valid;
      end
   end

   always_comb begin
      nxt_conf_data = reg_conf_data;
      nxt_conf_sel = reg_conf_sel;
      nxt_conf_slot = reg_conf_slot;
      nxt_set_valid = set_valid;

      // Set all lines to '0' by default.
      config_node = '0;
      link_en_valid = 1'b0;
      lut_conf_valid = 1'b0;
      lut_conf_valid_ni = 1'b0;

      // check if the out flit is valid
      if (flit_in.valid == 1) begin
         if (set_valid == 0) begin
            // The first flit determines output port or endpoint to be configured,
            // the routing information (port to forward), and the slot.
            // In case links are enabled or disabled in an endpoint the first
            // flit determines if a flit should be enabled or disabled (data),
            // the endpoint (sel), and the link (slot).
            nxt_conf_sel = flit_in.data[3:0];
            nxt_conf_data = flit_in.data[7:4];
            nxt_conf_slot = flit_in.data[15:8];
            nxt_set_valid = 1'b1;
         end else begin
            // The second flit determines the NI/router to configure and if a
            // slot table is to be configured or a link to be enabled or disabled.
            config_node = node_sel[$clog2(NODES)-1:0];
            if (link_en)
               link_en_valid = 1'b1;
            else if (ni_sel)
               lut_conf_valid_ni = 1'b1;
            else
               lut_conf_valid = 1'b1;
            nxt_set_valid = 1'b0;
         end
      end
   end

endmodule // noc_control_module_slot_conf
