/* Copyright (c) 2018 by the author(s)
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
 * Synchronous Standard FIFO (one clock) with two independent read ports.
 * Each word must be read on both ports. This is needed to implement 1+1
 * protection in the NI.
 *
 * The memory block in this FIFO is following the "RAM HDL Coding Guidelines"
 * of Xilinx (UG901) to enable placing the FIFO memory into block ram during
 * synthesis.
 *
 * Author(s):
 *   Philipp Wagner <philipp.wagner@tum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module fifo_singleclock_dual_rd_port #(
   parameter WIDTH = 8,
   parameter DEPTH = 32,
   parameter PROG_FULL = 0
)(
   input                         clk,
   input                         rst,

   input [(WIDTH-1):0]           din,
   input                         wr_en,
   output                        full,
   output                        prog_full,

   output reg [1:0][(WIDTH-1):0] dout,
   input [1:0]                   rd_en,
   output [1:0]                  empty
);
   localparam AW = $clog2(DEPTH);

   // ensure that parameters are set to allowed values
   initial begin
      if ((1 << $clog2(DEPTH)) != DEPTH) begin
         $fatal("fifo_singleclock_standard: the DEPTH must be a power of two.");
      end
   end

   reg [AW-1:0] wr_addr;
   reg [AW-1:0] rd_addr_a;
   reg [AW-1:0] rd_addr_b;
   wire         fifo_write;
   wire         fifo_read_a;
   wire         fifo_read_b;
   reg [AW-1:0] rd_count_a;
   reg [AW-1:0] rd_count_b;

   // generate control signals
   assign empty[0]    = (rd_count_a[AW-1:0] == 0);
   assign empty[1]    = (rd_count_b[AW-1:0] == 0);
   assign prog_full   = PROG_FULL == 0 ? 0 : ((rd_count_a[AW-1:0] >= PROG_FULL) || (rd_count_b[AW-1:0] >= PROG_FULL));
   assign full        = (rd_count_a[AW-1:0] == (DEPTH-1)) || (rd_count_b[AW-1:0] == (DEPTH-1));
   assign fifo_read_a = rd_en[0] & ~empty[0];
   assign fifo_read_b = rd_en[1] & ~empty[1];
   assign fifo_write  = wr_en & ~full;

   // address logic
   always_ff @(posedge clk) begin
      if (rst) begin
         wr_addr[AW-1:0]      <= 'd0;
         rd_addr_a[AW-1:0]    <= 'b0;
         rd_addr_b[AW-1:0]    <= 'b0;
         rd_count_a[AW-1:0]   <= 'b0;
         rd_count_b[AW-1:0]   <= 'b0;
      end else begin
         // Update rd/wr pointers
         if (fifo_write) begin
            wr_addr[AW-1:0] <= wr_addr[AW-1:0] + 'd1;
         end
         if (fifo_read_a) begin
            rd_addr_a[AW-1:0] <= rd_addr_a[AW-1:0] + 'd1;
         end
         if (fifo_read_b) begin
            rd_addr_b[AW-1:0] <= rd_addr_b[AW-1:0] + 'd1;
         end

         // Update rd counts
         if (fifo_write) begin
            if (!fifo_read_a) begin
               rd_count_a[AW-1:0] <= rd_count_a[AW-1:0] + 'd1;
            end
            if (!fifo_read_b) begin
               rd_count_b[AW-1:0] <= rd_count_b[AW-1:0] + 'd1;
            end
         end else begin
            if (fifo_read_a) begin
               rd_count_a[AW-1:0] <= rd_count_a[AW-1:0] - 'd1;
            end
            if (fifo_read_b) begin
               rd_count_b[AW-1:0] <= rd_count_b[AW-1:0] - 'd1;
            end
         end
      end
   end

   // generic dual-port, single clock memory
   reg [WIDTH-1:0] ram [DEPTH-1:0];

   // write
   always_ff @(posedge clk) begin
      if (fifo_write) begin
         ram[wr_addr] <= din;
      end
   end

   // read
   always_ff @(posedge clk) begin
      if (fifo_read_a) begin
         dout[0] <= ram[rd_addr_a];
      end
      if (fifo_read_b) begin
         dout[1] <= ram[rd_addr_b];
      end
   end
endmodule
