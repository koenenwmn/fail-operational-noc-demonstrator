/* Copyright (c) 2017-2020 by the author(s)
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
 * Buffer for NoC packets
 *
 * Author(s):
 *   Stefan Wallentowitz <stefan@wallentowitz.de>
 *   Wei Song <wsong83@gmail.com>
 *   Max Koenen <max.koenen@tum.de>
 */

/**
 * FIFO buffer for NoC use cases
 *
 * This FIFO buffer for NoC use cases has 1 clock cycle minimum delay from input
 * to output and is coded according to the "Vivado User Guide UG901", allowing
 * it to be synthesized using LUT RAM.
 * The actual depth is DEPTH + 1 because of the output register stage.
 * The FIFO provides a feature which will only signal a valid flit at the output
 * if a full packet is stored inside the buffer (i.e. at least one last-flit is
 * stored). If this feature is activated (FULLPACKET = 1) the size of the packet
 * can be read from the 'packet_size' output.
 */
module noc_buffer #(
   parameter FLIT_WIDTH = 32,
   parameter DEPTH = 16,   // must be a power of 2
   parameter FULLPACKET = 0,
   parameter FULLPACKETVALID = 0,

   localparam AW = $clog2(DEPTH), // the width of the index
   localparam SIZE_DEPTH = DEPTH / 2,
   localparam SIZE_AW = $clog2(SIZE_DEPTH)
)(
   input clk,
   input rst,

   // FIFO input side
   input [FLIT_WIDTH-1:0]        in_flit,
   input                         in_last,
   input                         in_valid,
   output                        in_ready,

   //FIFO output side
   output reg [FLIT_WIDTH-1:0]   out_flit,
   output reg                    out_last,
   output                        out_valid,
   input                         out_ready,

   output [AW:0]                 packet_size
);

   // Ensure that parameters are set to allowed values
   initial begin
      if ((1 << $clog2(DEPTH)) != DEPTH) begin
         $fatal("noc_buffer: the DEPTH must be a power of two.");
      end
   end

   reg [AW-1:0]   wr_addr;
   reg [AW-1:0]   rd_addr;
   reg [AW:0]     rd_count;
   wire           fifo_read;
   wire           fifo_write;
   wire           read_ram;
   wire           write_through;
   wire           write_ram;

   assign in_ready = (rd_count < DEPTH + 1); // The actual depth is DEPTH+1 because of the output register
   assign fifo_read = out_valid & out_ready;
   assign fifo_write = in_ready & in_valid;
   assign read_ram = fifo_read & (rd_count > 1);
   assign write_through = ((rd_count == 0) | ((rd_count == 1) & fifo_read));
   assign write_ram = fifo_write & ~write_through;

   // Address logic
   always_ff @(posedge clk) begin
      if (rst) begin
         wr_addr <= 'b0;
         rd_addr <= 'b0;
         rd_count <= 'b0;
      end else begin
         if (fifo_write & ~fifo_read)
            rd_count <=  rd_count + 1'b1;
         else if (fifo_read & ~fifo_write)
            rd_count <= rd_count - 1'b1;
         if (write_ram)
            wr_addr <= wr_addr + 1'b1;
         if (read_ram)
            rd_addr <= rd_addr + 1'b1;
      end
   end

   // Generic dual-port, single clock memory
   reg [FLIT_WIDTH:0] ram [DEPTH-1:0];

   // Write
   always_ff @(posedge clk) begin
      if (write_ram) begin
         ram[wr_addr] <= {in_last, in_flit};
      end
   end

   // Read
   always_ff @(posedge clk) begin
      if (read_ram) begin
         out_flit <= ram[rd_addr][0 +: FLIT_WIDTH];
         out_last <= ram[rd_addr][FLIT_WIDTH];
      end else if (fifo_write & write_through) begin
         out_flit <= in_flit;
         out_last <= in_last;
      end
   end

   generate
      if (FULLPACKET) begin
         reg [DEPTH:0] data_last_buf;
         wire [DEPTH:0] data_last_shifted;

         always @(posedge clk)
            if (rst)
               data_last_buf <= 0;
            else if (fifo_write)
               data_last_buf <= {data_last_buf, in_last};

            // Extra logic to get the packet size in a stable manner
         assign data_last_shifted = data_last_buf << DEPTH + 1 - rd_count;

         function logic [AW:0] find_first_one(input logic [DEPTH:0] data);
         automatic int i;
         for (i = DEPTH; i >= 0; i--)
            if (data[i]) return i;
         return DEPTH + 1;
         endfunction // size_count

         assign out_valid = (rd_count > 0) & |data_last_shifted;
         assign packet_size = DEPTH + 1 - find_first_one(data_last_shifted);
      end else if (FULLPACKETVALID) begin
         reg [$clog2(SIZE_DEPTH+1)-1:0] queue;

         always_ff @(posedge clk) begin
            if (rst) begin
               queue <= '0;
            end else begin
               if (fifo_write & in_last & ~(fifo_read & out_last))
                  queue <= queue + 1'b1;
               else if (fifo_read & out_last & ~(fifo_write & in_last))
                  queue <= queue - 1'b1;
            end
         end

         assign out_valid = |queue;

         /*
         if (FULLPACKET) begin
            // Generic dual-port, single clock memory for packet sizes, half the
            // size of the actual ram
            reg [AW:0] pkt_sizes [SIZE_DEPTH-1:0];
            reg [AW:0] curr_size_in;
            reg [AW:0] curr_size_out;
            reg [SIZE_AW-1:0] size_wr_addr;
            reg [SIZE_AW-1:0] size_rd_addr;

            wire write_size;
            wire write_size_through;
            wire write_size_to_fifo;
            wire read_size_from_fifo;
            wire inc_curr_size_in;
            wire dec_curr_size_out;

            assign write_size = fifo_write & in_last;
            assign write_size_through = write_size & ((queue == 0) | ((queue == 1) & (curr_size_out == 1) & fifo_read));
            assign write_size_to_fifo = write_size & ~write_size_through;
            assign read_size_from_fifo = (queue > 1) & (curr_size_out == 1);
            assign inc_curr_size_in = fifo_write & ~write_size;
            assign dec_curr_size_out = (curr_size_out > 0) & fifo_read;

            assign packet_size = curr_size_out;

            always_ff @(posedge clk) begin
               if (rst) begin
                  curr_size_in <= '0;
                  curr_size_out <= '0;
                  size_wr_addr <= '0;
                  size_rd_addr <= '0;
               end else begin
                  if (write_size_to_fifo) begin
                     pkt_sizes[size_wr_addr] <= curr_size_in + 1'b1;
                     size_wr_addr <= wr_addr + 1'b1;
                  end

                  if (write_size)
                     curr_size_in <= '0;
                  else if (inc_curr_size_in)
                     curr_size_in <= curr_size_in + 1'b1;

                  if (write_size_through)
                     curr_size_out <= curr_size_in + 1'b1;
                  else if (read_size_from_fifo) begin
                     curr_size_out <= pkt_sizes[size_rd_addr];
                     size_rd_addr <= size_rd_addr + 1'b1;
                  end else if (dec_curr_size_out)
                     curr_size_out <= curr_size_out - 1'b1;
               end
            end
         end else begin
            assign packet_size = 0;
         end
         */
         assign packet_size = 0;
      end else begin
         assign out_valid = rd_count > 0;
         assign packet_size = 0;
      end
   endgenerate
endmodule // noc_buffer
