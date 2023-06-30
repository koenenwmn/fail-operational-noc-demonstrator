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
 * This module selects the correct slave, that is addressed by the Wishbone Bus.
 * It also combines some signals, so other modules implementing a generic bus
 * model can be addressed using the Wishbone Interface.
 *
 *
 * Author(s):
 *   Alex Ostertag <ga76zox@mytum.de>
 */

 module ni_slave_decode #(
    parameter SLAVES = 3,
    parameter SLAVE_ID_WIDTH = 4,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    localparam SEL_WIDTH = DATA_WIDTH / 8
)(
   input          clk,
   input          rst,

   // Master Side WB Interface
   input [ADDR_WIDTH-1:0]                 wb_addr,
   input [DATA_WIDTH-1:0]                 wb_data_in,
   input                                  wb_cyc,
   input                                  wb_stb,
   input [SEL_WIDTH-1:0]                  wb_sel,        // not used
   input                                  wb_we,
   input [2:0]                            wb_cti,        // not used
   input [1:0]                            wb_bte,        // not used
   output logic [DATA_WIDTH-1:0]          wb_data_out,
   output logic                           wb_ack,
   output logic                           wb_err,
   output                                 wb_rty,        // not used

   // Slaves Side: Generic Bus Interface
   output [ADDR_WIDTH-1:0]                bus_addr,
   output                                 bus_we,
   output [SLAVES-1:0]                    bus_en,
   output [DATA_WIDTH-1:0]                bus_data_in,
   input [SLAVES-1:0][DATA_WIDTH-1:0]     bus_data_out,
   input [SLAVES-1:0]                     bus_ack,
   input [SLAVES-1:0]                     bus_err
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (SLAVE_ID_WIDTH < $clog2(SLAVES)) begin
         $fatal("ni_slave_decode: SLAVE_ID_WIDTH too small for max Slaves.");
      end
   end

   wire [SLAVES-1:0]    slave_select;
   wire                 select_error;
// -----------------------------------------------------------------------------

   genvar i;
   generate
      for(i = 0; i < SLAVES; i++) begin
         assign slave_select[i] = (wb_addr[ADDR_WIDTH-1 -: SLAVE_ID_WIDTH] == i);
         // Combine these signals, so generic bus modules can be addressed
         assign bus_en[i] = slave_select[i] & wb_cyc & wb_stb;
      end
   endgenerate
   // If no slave is selected, there is probably an error
   assign select_error = ~^slave_select;

   // WB Interface to Bus: direct connections
   assign bus_addr = wb_addr;
   assign bus_we = wb_we;
   assign bus_data_in = wb_data_in;

   // Mux signals from the addressed slave onto the WB Bus
   always_comb begin
      integer i;
      wb_data_out = 32'h0;
      wb_ack = 1'b0;
      wb_err = select_error;
      for(i = 0; i < SLAVES; i++) begin
         if(slave_select[i]) begin
            wb_data_out = bus_data_out[i];
            wb_ack = bus_ack[i];
            wb_err = wb_err | bus_err[i];
         end
      end
   end
   assign wb_rty = 1'b0;

endmodule // ni_slave_decode
