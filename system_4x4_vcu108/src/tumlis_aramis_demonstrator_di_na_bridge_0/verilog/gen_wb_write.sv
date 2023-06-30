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
 * The module passes the incoming data to its corresponding endpoint in the NI
 * and generates the necessary WB signals.
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module gen_wb_write #(
   parameter NUM_BE_ENDPOINTS = 1,
   parameter NUM_TDM_ENDPOINTS = 1,
   parameter MAX_DI_PKT_LEN = 12,
   parameter NOC_FLIT_WIDTH = 32,
   parameter DEPTH = 16
)(
   input                                     clk,
   input                                     rst,
   input                                     enable,
   input [$clog2(DEPTH):0]                   packet_size,
   input [(NOC_FLIT_WIDTH-1):0]              in_flit_data,
   input                                     in_flit_valid,
   input                                     in_flit_last,
   output logic                              in_flit_ready,

   input                                     wb_err_i,   // currently not in use, but might be added in the future
   input                                     wb_ack_i,
   output logic [31:0]                       wb_adr_o,
   output logic [(NOC_FLIT_WIDTH-1):0]       wb_dat_o,
   output logic                              wb_stb_o,
   output logic                              wb_cyc_o,
   output logic                              req
);

   reg [31:0]     reg_adr_o;
   logic [31:0]   nxt_adr_o;

   enum {IDLE, ENDPOINT, SIZE, WRITE, ERR} state, nxt_state;

   assign wb_adr_o = reg_adr_o;

   always @(posedge clk) begin
      if (rst) begin
         state <= IDLE;
         reg_adr_o <= 0;
      end else begin
         state <= nxt_state;
         reg_adr_o <= nxt_adr_o;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_adr_o = reg_adr_o;

      wb_dat_o = 0;
      wb_stb_o = 0;
      wb_cyc_o = 0;

      req = 0;
      in_flit_ready = 0;

      case(state)
         IDLE: begin
            if (in_flit_valid) begin
               req = 1;
               if (enable) begin
                  nxt_state = ENDPOINT;
               end
            end
         end
         ENDPOINT: begin
            req = 1;
            if(in_flit_valid) begin
               // select endpoint here
               if(in_flit_data[15]==0) begin
                  // BE
                  if(in_flit_data[14:0] > NUM_BE_ENDPOINTS) begin
                     // given endpoint isn't valid
                     nxt_state = ERR;
                  end else begin
                     nxt_adr_o[19:13] = in_flit_data[14:0] + 1;
                     nxt_adr_o[23:20] = 4'h1;
                     nxt_state = SIZE;
                     in_flit_ready = 1;
                  end
               end else begin
                  // TDM
                  if(in_flit_data[14:0] > NUM_TDM_ENDPOINTS) begin
                     // given endpoint isn't valid
                     nxt_state = ERR;
                  end else begin
                     nxt_adr_o[19:13] = in_flit_data[14:0] + 1;
                     nxt_adr_o[23:20] = 4'h2;
                     nxt_state = WRITE;
                     in_flit_ready = 1;
                  end
               end
            end
         end
         SIZE: begin
            req = 1;
            // send size of packet that is written
            wb_dat_o = {{(32-$clog2(DEPTH)){1'b0}},packet_size};
            wb_stb_o = 1;
            wb_cyc_o = 1;
            if(wb_ack_i) begin
               nxt_state = WRITE;
            end
         end
         WRITE: begin
            req = 1;
            wb_stb_o = 1;
            wb_cyc_o = 1;
            wb_dat_o = in_flit_data;
            if(wb_ack_i) begin
               in_flit_ready = 1;
               if(in_flit_last) begin
                  req = 0;
                  nxt_state = IDLE;
               end
            end
         end
         ERR: begin
            // wait for last di-flit to pass
            if(in_flit_last == 1) begin
               nxt_state = IDLE;
            end
            in_flit_ready = 1;
         end
      endcase
   end
endmodule
