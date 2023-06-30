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
 * This module manages the access to the bus of the di_na_bridge module and
 * activates/deactivates the endpoints of the NI.
 * The priority is:
 *   activation/deactivation > read operation > write operation
 * 
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module di_na_bridge_arbiter #(
   parameter NUM_BE_ENDPOINTS    = 2,
   parameter NUM_TDM_ENDPOINTS   = 2,
   localparam MAX_NUM_EP         = NUM_BE_ENDPOINTS > NUM_TDM_ENDPOINTS ? NUM_BE_ENDPOINTS : NUM_TDM_ENDPOINTS,
   localparam CTN_WIDTH          = $clog2(MAX_NUM_EP+1)
)(
   input                clk,
   input                rst,
   input                req_rd,
   input                req_wr,
   input                req_be_active,
   input                req_tdm_active,

   input [31:0]         rd_wb_adr_o,
   input                rd_wb_cyc_o,
   input                rd_wb_stb_o,

   input [31:0]         wr_wb_adr_o,
   input [31:0]         wr_wb_dat_o,
   input                wr_wb_stb_o,
   input                wr_wb_cyc_o,

   output logic [31:0]  wb_adr_o,
   output logic [31:0]  wb_dat_o,
   output logic         wb_cyc_o,
   output logic         wb_stb_o,
   output [3:0]         wb_sel_o,
   output logic         wb_we_o,

   output               gnt_rd,
   output               gnt_wr,
   output               be_active,
   output               tdm_active
);

   enum {IDLE, READ, WRITE, ACT_EP} state, nxt_state;

   reg   reg_gnt_rd;
   reg   reg_gnt_wr;
   logic nxt_gnt_rd;
   logic nxt_gnt_wr;

   assign gnt_rd = reg_gnt_rd;
   assign gnt_wr = reg_gnt_wr;

   reg   reg_be_active;
   reg   reg_tdm_active;
   logic nxt_be_active;
   logic nxt_tdm_active;
   wire  update_be_active;
   wire  update_tdm_active;
   wire  update_active;

   assign update_be_active = reg_be_active != req_be_active;
   assign update_tdm_active = reg_tdm_active != req_tdm_active;
   assign update_active = update_tdm_active | update_be_active;

   assign be_active = reg_be_active;
   assign tdm_active = reg_tdm_active;

   reg [CTN_WIDTH:0]    reg_ep_cnt;
   logic [CTN_WIDTH:0]  nxt_ep_cnt;

   assign wb_sel_o = 0; // hard-wired since we don't need it

   always @(posedge clk) begin
      if (rst) begin
         state <= IDLE;
         reg_gnt_rd <= 0;
         reg_gnt_wr <= 0;
         reg_be_active <= 0;
         reg_tdm_active <= 0;
         reg_ep_cnt <= 0;
      end else begin
         state <= nxt_state;
         reg_gnt_rd <= nxt_gnt_rd;
         reg_gnt_wr <= nxt_gnt_wr;
         reg_be_active <= nxt_be_active;
         reg_tdm_active <= nxt_tdm_active;
         reg_ep_cnt <= nxt_ep_cnt;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_gnt_wr = reg_gnt_wr;
      nxt_gnt_rd = reg_gnt_rd;
      nxt_be_active = reg_be_active;
      nxt_tdm_active = reg_tdm_active;
      nxt_ep_cnt = reg_ep_cnt;
      wb_adr_o = 0;
      wb_dat_o = 0;
      wb_cyc_o = 0;
      wb_stb_o = 0;
      wb_we_o = 0;

      case (state)
         IDLE: begin
            // Activation/deactivation of EPs has priority
            if (update_active) begin
               nxt_ep_cnt = 1; // enpoints start with '1'
               nxt_state = ACT_EP;
            // Read operation has higher priority than write operation
            end else if (req_rd) begin
               nxt_gnt_rd = 1'b1;
               nxt_state = READ;
            end else if (req_wr) begin
               nxt_gnt_wr = 1'b1;
               nxt_state = WRITE;
            end
         end
         READ: begin
            wb_adr_o = rd_wb_adr_o;
            wb_cyc_o = rd_wb_cyc_o;
            wb_stb_o = rd_wb_stb_o;
            if (!req_rd) begin
               nxt_state = IDLE;
               nxt_gnt_rd = 1'b0;
            end
         end
         WRITE: begin
            wb_we_o = 1;
            wb_adr_o = wr_wb_adr_o;
            wb_dat_o = wr_wb_dat_o;
            wb_cyc_o = wr_wb_cyc_o;
            wb_stb_o = wr_wb_stb_o;
            if (!req_wr) begin
               nxt_state = IDLE;
               nxt_gnt_wr = 1'b0;
            end
         end
         ACT_EP: begin
            wb_we_o = 1;
            wb_cyc_o = 1;
            wb_stb_o = 1;
            wb_adr_o[5:2] = 4'h1; // status/activate register
            wb_adr_o[19:13] = reg_ep_cnt; // endpoint
            if (update_tdm_active) begin
               wb_adr_o[23:20] = 4'h2; // TDM submodule
               wb_dat_o[0] = req_tdm_active;
               if (reg_ep_cnt == NUM_TDM_ENDPOINTS) begin
                  nxt_tdm_active = req_tdm_active;
                  nxt_state = IDLE;
               end
            end else begin
               wb_adr_o[23:20] = 4'h1; // BE submodule
               wb_dat_o[0] = req_be_active;
               if (reg_ep_cnt == NUM_BE_ENDPOINTS) begin
                  nxt_be_active = req_be_active;
                  nxt_state = IDLE;
               end
            end
            nxt_ep_cnt = reg_ep_cnt + 1;
         end
      endcase
   end
endmodule
