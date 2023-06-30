/* Copyright (c) 2020 by the author(s)
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
 * Takes the bus signals between wishbone-bus and NA and decides which
 * path to enable. Also decodes endpoint.
 * enable: 0 be_send
 *         1 be_receive
 *         2 tdm_send
 *         3 tdm_receive
 *
 * Author(s):
 *   Adrian Schiechel <adrian.schiechel@tum.de>
 */


`timescale 1ns/1ps

module sm_input_decode #(
   parameter NUM_TDM_ENDPOINTS = 4,
   localparam ENDP_WIDTH = NUM_TDM_ENDPOINTS > 1 ? $clog2(NUM_TDM_ENDPOINTS) : 1
)(
   input clk, rst,

   input [31:0]     wb_na_addr,
   input [31:0]     wb_na_data_in,    // sent data
   input [31:0]     wb_na_data_out,   // received data
   input            wb_na_we,
   input            wb_na_cyc,
   input            wb_na_stb,
   input            wb_na_ack,
   output [3:0]     enable,
   output [31:0]    data,
   output [ENDP_WIDTH-1:0] ep
);

   reg [31:0]     na_addr;
   reg [31:0]     na_data_in;
   reg [31:0]     na_data_out;
   reg            na_we;
   reg            na_cyc;
   reg            na_stb;
   reg            na_ack;

   wire [3:0]       select;

   always_ff @(posedge clk) begin
      if (rst) begin
         na_addr <= 0;
         na_data_in <= 0;
         na_data_out <= 0;
         na_we <= 0;
         na_cyc <= 0;
         na_stb <= 0;
         na_ack <= 0;
      end else begin
         na_addr <= wb_na_addr;
         na_data_in <= wb_na_data_in;
         na_data_out <= wb_na_data_out;
         na_we <= wb_na_we;
         na_cyc <= wb_na_cyc;
         na_stb <= wb_na_stb;
         na_ack <= wb_na_ack;
      end
   end

   // NA_BASE:       0xe0000000
   // BE: NA_BASE +    0x100000
   // TDM: NA_BASE +   0x200000
   // EP_OFFSET:         0x2000
   // REG_SEND = REG_RECV = 0x0 --> differentiate with wb_na_we
   // SEND: TDM_BASE+ep*EP_OFFSET+REG_SEND
   // RECV: TDM_BASE+ep*EP_OFFSET+REG_RECV

   assign select[0] = ((na_addr[23:20] == 1) & (na_we == 1)); //be_send
   assign select[1] = ((na_addr[23:20] == 1) & (na_we == 0)); //be_receive
   assign select[2] = ((na_addr[23:20] == 2) & (na_we == 1)); //tdm_send
   assign select[3] = ((na_addr[23:20] == 2) & (na_we == 0)); //tdm_receive

   genvar i;
   generate
      for(i = 0; i < 4; i++) begin
         // 0x0*** does not address channel, only 0x0 used for rd/wr channel
         assign enable[i] = select[i] & na_cyc & na_stb & na_ack & (na_addr[3:0] == 0) & (na_addr[19:13] != 0);
      end
   endgenerate

   assign ep = na_addr[ENDP_WIDTH+12:13] - 1; // each channel has offset of 0x2000
   assign data = (na_we == 1) ? na_data_in : na_data_out;

endmodule // sm_input_decode
