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
 * The module reads data from the network interface and forwards it to the flit
 * buffer. It only starts reading from the NI when it can be assured that an
 * entire packet can be read and inserted to the buffer, i.e. when the buffer is
 * empty.
 *
 * Author(s):
 *   Lorenz Völk <lorenz.voelk@web.de>
 *   Stefan Keller <stefan.keller@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module fsm_na_read #(
   parameter MAX_NOC_PKT_LEN     = 10,
   parameter NOC_FLIT_WIDTH      = 32,
   parameter NUM_BE_ENDPOINTS    = 1,
   parameter NUM_TDM_ENDPOINTS   = 1,

   localparam EP_W = NUM_BE_ENDPOINTS > NUM_TDM_ENDPOINTS ? $clog2(NUM_BE_ENDPOINTS) : $clog2(NUM_TDM_ENDPOINTS),
   localparam CNT_W = $clog2(MAX_NOC_PKT_LEN+1)
)(
   input                         clk,
   input                         rst_debug,
   input                         rst_sys,
   input                         irq_tdm,
   input                         irq_be,
   input                         enable,
   output logic                  req,

   input                         wb_ack_i,
   input [NOC_FLIT_WIDTH-1:0]    wb_dat_i,
   input                         wb_err_i,   // currently not in use, but might be added in the future
   output logic [31:0]           wb_adr_o,   // [19:13] for endpoint selection [5:2] hard-coded to zero
   output logic                  wb_cyc_o,
   output logic                  wb_stb_o,

   // Signals from/to flit buffer
   output logic [NOC_FLIT_WIDTH-1:0]   out_flit_data,
   output logic                        out_flit_valid,
   output logic                        out_flit_last,
   input                               buffer_empty,
   // Signals that the written flit is 16 bit wide.
   // This is used for the endpoint information of a packet.
   output logic                        out_flit_16
);

   reg [EP_W-1:0]    endpoint;
   logic [EP_W-1:0]  nxt_endpoint;
   reg [EP_W-1:0]    num_endpoints;
   logic [EP_W-1:0]  nxt_num_endpoints;
   reg               ep_tdm;
   logic             nxt_ep_tdm;

   reg [CNT_W-1:0]   data_counter;
   logic [CNT_W-1:0] nxt_data_counter;
   reg [15:0]        size;
   logic [15:0]      nxt_size;

   // FSM
   enum {
      IDLE, CHECK_ENDPOINT, BUS_READ
   } state, nxt_state;

   always @(posedge clk) begin
      if (rst_debug) begin
         state <= IDLE;
         endpoint <= 1;
         num_endpoints <= 0;
         ep_tdm <= 0;
         data_counter <= 0;
         size <= 0;
      end else begin
         state <= nxt_state;
         endpoint <= nxt_endpoint;
         num_endpoints <= nxt_num_endpoints;
         ep_tdm <= nxt_ep_tdm;
         data_counter <= nxt_data_counter;
         size <= nxt_size;
      end
   end

   always_comb begin
      nxt_state = state;
      nxt_endpoint = endpoint;
      nxt_num_endpoints = num_endpoints;
      nxt_ep_tdm = ep_tdm;
      nxt_data_counter = data_counter;
      nxt_size = size;

      wb_cyc_o = 0;
      wb_stb_o = 0;
      wb_adr_o = 0;
      out_flit_data = 0;
      out_flit_valid = 0;
      out_flit_last = 0;
      out_flit_16 = 0;
      req = 0;

      case (state)
         IDLE: begin
            if ((irq_tdm | irq_be) & buffer_empty & ~rst_sys) begin
               req = 1;
               if (enable) begin
                  nxt_endpoint = 0;
                  nxt_state = CHECK_ENDPOINT;
                  // Always check TDM enpoints first
                  if (irq_tdm) begin
                     nxt_ep_tdm = 1'b1;
                     nxt_num_endpoints = NUM_TDM_ENDPOINTS;
                  end else if (irq_be) begin
                     nxt_ep_tdm = 1'b0;
                     nxt_num_endpoints = NUM_BE_ENDPOINTS;
                  end
               end
            end
         end
         CHECK_ENDPOINT: begin
            req = 1;
            wb_stb_o = 1;
            wb_cyc_o = 1;
            wb_adr_o[19:13] = endpoint + 1;
            wb_adr_o[23:20] = ep_tdm ? 4'h2 : 4'h1;
            if (wb_ack_i) begin
               if (wb_dat_i == 0 && endpoint < num_endpoints - 1) begin
                  nxt_endpoint = endpoint + 1;
               end else if (wb_dat_i != 0) begin
                  // Store number of flits to read
                  nxt_size = wb_dat_i[15:0];
                  // Store number of current endpoint
                  out_flit_data[14:0] = endpoint;
                  // Set bit indicating TDM or BE
                  out_flit_data[15] = ep_tdm ? 1'b1 : 1'b0;
                  // Signal 16 bit word to buffer
                  out_flit_16 = 1;
                  out_flit_valid = 1'b1;
                  nxt_state = BUS_READ;
                  nxt_data_counter = 1;
               end else if (wb_dat_i == 0 && endpoint == num_endpoints - 1) begin
                  nxt_state = IDLE;
               end
            end
            if (rst_sys) begin
               nxt_state = IDLE;
            end
         end
         BUS_READ: begin
            req = 1;
            wb_stb_o = 1;
            wb_cyc_o = 1;
            wb_adr_o[19:13] = endpoint + 1;
            wb_adr_o[23:20] = ep_tdm ? 4'h2 : 4'h1;
            if (wb_ack_i) begin
               nxt_data_counter = data_counter + 1;
               out_flit_data = wb_dat_i;
               out_flit_valid = 1'b1;
               if (data_counter >= size) begin
                  nxt_state = IDLE;
                  out_flit_last = 1'b1;
               end
            end
            // Send incomplete packet (rather than stalling indefinitely) if
            // system is reset
            if (rst_sys) begin
               out_flit_valid = 1'b1;
               out_flit_last = 1'b1;
            end
         end
      endcase
   end
endmodule
