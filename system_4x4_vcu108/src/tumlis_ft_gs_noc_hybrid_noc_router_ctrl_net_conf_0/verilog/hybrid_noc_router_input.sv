/* Copyright (c) 2018-2019 by the author(s)
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
 *
 * This is the input port for the hybrid noc router. It only handles the BE
 * traffic as the TDM traffic is directly forwarded to the output ports.
 * The input port checks the header flit for the requested output port and
 * requests that port to forward the BE traffic.
 * Currently the minimum DEPTH is 4 as the minimum DEPTH of the used FIFO is 2
 * and the lookup contains two additional register stages.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_router_input #(
   parameter FLIT_WIDTH = 'x,
   parameter PORTS = 'x,
   parameter INPUT_ID = 'x,
   parameter DEPTH = 4,    // The actual depth is DEPTH + 1 because of the output register of the noc_buffer
   parameter ENABLE_DR = 0,
   parameter TABLE_WIDTH = 0,
   parameter LOCAL = 0,
   parameter DESTS = 0,
   parameter [DESTS*TABLE_WIDTH-1:0] ROUTES = {DESTS*TABLE_WIDTH{1'b1}}
)(
   input clk,
   input rst,

   input [FLIT_WIDTH-1:0]     in_flit,
   input                      in_valid,
   input                      in_last,
   output                     in_ready,

   output [FLIT_WIDTH-1:0]    out_flit,
   output [PORTS-1:0]         out_valid,
   output                     out_last,
   input [PORTS-1:0]          out_ready
);

   wire [FLIT_WIDTH-1:0]      buffer_flit;
   wire                       buffer_valid, buffer_last, buffer_ready;

   noc_buffer #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .DEPTH(DEPTH))
   u_be_buffer(
      .clk           (clk),
      .rst           (rst),
      .in_flit       (in_flit),
      .in_valid      (in_valid),
      .in_last       (in_last),
      .in_ready      (in_ready),
      .out_flit      (buffer_flit),
      .out_valid     (buffer_valid),
      .out_last      (buffer_last),
      .out_ready     (buffer_ready),
      .packet_size   ()
   );

   generate
      if (ENABLE_DR) begin
         hybrid_noc_router_lookup_dr #(
            .FLIT_WIDTH(FLIT_WIDTH),
            .PORTS(PORTS),
            .TABLE_WIDTH(TABLE_WIDTH),
            .LOCAL(LOCAL),
            .DESTS(DESTS),
            .ROUTES(ROUTES))
         u_be_lookup(
            .clk           (clk),
            .rst           (rst),
            .in_flit       (buffer_flit),
            .in_valid      (buffer_valid),
            .in_last       (buffer_last),
            .in_ready      (buffer_ready),
            .out_flit      (out_flit),
            .out_valid     (out_valid),
            .out_last      (out_last),
            .out_ready     (out_ready)
         );
      end else begin
         hybrid_noc_router_lookup_sr #(
            .FLIT_WIDTH(FLIT_WIDTH),
            .PORTS(PORTS),
            .INPUT_ID(INPUT_ID))
         u_be_lookup(
            .clk           (clk),
            .rst           (rst),
            .in_flit       (buffer_flit),
            .in_valid      (buffer_valid),
            .in_last       (buffer_last),
            .in_ready      (buffer_ready),
            .out_flit      (out_flit),
            .out_valid     (out_valid),
            .out_last      (out_last),
            .out_ready     (out_ready)
         );
      end
   endgenerate

endmodule // hybrid_noc_router_input
