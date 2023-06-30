/* Copyright (c) 2017-2018 by the author(s)
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
 * Synchronous First-Word Fall-Through (FWFT) FIFO with two independent read
 * ports. Each word must be read on both ports. This is needed to implement 1+1
 * protection in the NI.
 *
 * This FIFO implementation wraps the FIFO with standard read characteristics
 * to have first-word fall-through read characteristics.
 *
 * Author(s):
 *   Philipp Wagner <philipp.wagner@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module fifo_singleclock_dual_rd_port_fwft #(
   parameter WIDTH = 8,
   parameter DEPTH = 32,
   parameter PROG_FULL = 0
)(
   input                      clk,
   input                      rst,

   input [(WIDTH-1):0]        din,
   input                      wr_en,
   output                     full,
   output                     prog_full,

   output [1:0][(WIDTH-1):0]  dout,
   input [1:0]                rd_en,
   output [1:0]               empty
);

   wire [1:0][WIDTH-1:0]      fifo_dout;
   wire [1:0]                 fifo_empty, fifo_rd_en;

   // Synchronous FIFO with standard (non-FWFT) read characteristics
   fifo_singleclock_dual_rd_port #(
      .WIDTH(WIDTH),
      .DEPTH(DEPTH),
      .PROG_FULL(PROG_FULL))
   u_fifo (
      .rst(rst),
      .clk(clk),
      .rd_en(fifo_rd_en),
      .dout(fifo_dout),
      .empty(fifo_empty),
      .wr_en(wr_en),
      .din(din),
      .full(full),
      .prog_full(prog_full)
   );

   // FWFT logic and registers
   fifo_fwft_logic #(
      .WIDTH(WIDTH))
   u_fwft_logic_a (
      .clk(clk),
      .rst(rst),
      .fifo_dout(fifo_dout[0]),
      .fifo_empty(fifo_empty[0]),
      .fifo_rd_en(fifo_rd_en[0]),
      .dout(dout[0]),
      .empty(empty[0]),
      .rd_en(rd_en[0])
   );

   fifo_fwft_logic #(
      .WIDTH(WIDTH))
   u_fwft_logic_b (
      .clk(clk),
      .rst(rst),
      .fifo_dout(fifo_dout[1]),
      .fifo_empty(fifo_empty[1]),
      .fifo_rd_en(fifo_rd_en[1]),
      .dout(dout[1]),
      .empty(empty[1]),
      .rd_en(rd_en[1])
   );

endmodule
