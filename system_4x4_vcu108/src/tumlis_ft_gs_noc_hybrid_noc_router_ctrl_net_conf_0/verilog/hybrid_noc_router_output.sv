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
 *
 * This is the output port for the hybrid noc router. It selects an input flit
 * according to the LUT and forwards it to the downstream router. In addition,
 * it arbitrates the BE traffic between the input ports and forwards BE traffic
 * whenever a TDM cycle is unassigned or unused.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_router_output #(
   parameter FLIT_WIDTH = 'x,
   parameter PORTS = 'x,
   parameter LUT_SIZE = 16,
   parameter BE_ENABLED = 1,
   parameter BE_PORTS = PORTS,
   parameter OUTPUT_ID = 'x,
   parameter BUFFER_DEPTH = 2
)(
   input    clk,
   input    rst,

   input [PORTS-1:0][FLIT_WIDTH-1:0]      tdm_in_flit,
   input [PORTS-1:0]                      tdm_in_valid,
   input [PORTS-1:0]                      tdm_in_last,

   input [BE_PORTS-1:0][FLIT_WIDTH-1:0]   be_in_flit,
   input [BE_PORTS-1:0]                   be_in_valid,
   input [BE_PORTS-1:0]                   be_in_last,
   output [BE_PORTS-1:0]                  be_in_ready,

   output [FLIT_WIDTH-1:0]                out_flit,
   output                                 out_last,
   output                                 tdm_out_valid,
   output                                 be_out_valid,
   input                                  be_out_ready,

   // Interface for writing to LUT.
   // Each output port has it's own LUT determining which input to forward.
   input [$clog2(PORTS+1)-1:0]            lut_conf_data,
   input [$clog2(PORTS)-1:0]              lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]           lut_conf_slot,
   input                                  lut_conf_valid
);

   // TDM wires
   wire [$clog2(PORTS+1)-1:0] tdm_select;
   wire [FLIT_WIDTH-1:0]      tdm_register_in_flit;
   wire                       tdm_register_in_valid;
   wire                       tdm_register_in_last;
   wire [FLIT_WIDTH-1:0]      tdm_register_out_flit;
   wire                       tdm_register_out_valid;
   wire                       tdm_register_out_last;

   // BE wires
   wire [$clog2(PORTS)-1:0]   be_select;
   wire [FLIT_WIDTH-1:0]      be_buffer_in_flit;
   wire                       be_buffer_in_valid;
   wire                       be_buffer_in_last;
   wire                       be_buffer_in_ready;
   wire [FLIT_WIDTH-1:0]      be_buffer_out_flit;
   wire                       be_buffer_out_valid;
   wire                       be_buffer_out_last;
   wire                       be_buffer_out_ready;

   //------------------------- Base TDM part ------------------------------//

   tdm_noc_slot_table #(
      .PORTS(PORTS),
      .LUT_SIZE(LUT_SIZE),
      .OUTPUT_ID(OUTPUT_ID))
   u_lut (
      .clk              (clk),
      .rst              (rst),
      .select           (tdm_select),

      .lut_conf_data    (lut_conf_data),
      .lut_conf_sel     (lut_conf_sel),
      .lut_conf_slot    (lut_conf_slot),
      .lut_conf_valid   (lut_conf_valid)
   );

   assign tdm_register_in_flit = tdm_in_flit[tdm_select];
   assign tdm_register_in_valid = (tdm_select == {$clog2(PORTS+1){1'b1}} ? 1'b0 : tdm_in_valid[tdm_select]);
   assign tdm_register_in_last = tdm_in_last[tdm_select];

   register_stage #(
      .FLIT_WIDTH(FLIT_WIDTH),
      .FLAGS(2))
   u_tdm_reg (
      .clk        (clk),
      .rst        (rst),

      .in_flit    (tdm_register_in_flit),
      .in_flags   ({tdm_register_in_valid, tdm_register_in_last}),
      .out_flit   (tdm_register_out_flit),
      .out_flags  ({tdm_register_out_valid, tdm_register_out_last})
   );

   generate
      if (BE_ENABLED) begin
         //------------------------- Source-routed BE part ----------------------//
         hybrid_noc_router_be_arbiter #(
            .PORTS(BE_PORTS))
         u_arbiter(
            .clk           (clk),
            .rst           (rst),
            .in_valid      (be_in_valid),
            .in_last       (be_in_last),
            .in_ready      (be_in_ready),
            .buffer_ready  (be_buffer_in_ready),
            .buffer_valid  (be_buffer_in_valid),
            .buffer_last   (be_buffer_in_last),
            .select        (be_select)
         );

         assign be_buffer_in_flit = be_in_flit[be_select];

         noc_buffer #(
            .FLIT_WIDTH(FLIT_WIDTH),
            .DEPTH(BUFFER_DEPTH))
         u_be_buffer(
            .clk           (clk),
            .rst           (rst),
            .in_flit       (be_buffer_in_flit),
            .in_valid      (be_buffer_in_valid),
            .in_last       (be_buffer_in_last),
            .in_ready      (be_buffer_in_ready),
            .out_flit      (be_buffer_out_flit),
            .out_valid     (be_buffer_out_valid),
            .out_last      (be_buffer_out_last),
            .out_ready     (be_buffer_out_ready),
            .packet_size   ()
         );

         //------------------------- Hybrid / output part -----------------------//

         assign tdm_out_valid = tdm_register_out_valid;
         assign be_out_valid = be_buffer_out_valid & ~tdm_register_out_valid;
         assign out_flit = tdm_register_out_valid ? tdm_register_out_flit : be_buffer_out_flit;
         assign out_last = tdm_register_out_valid & tdm_register_out_last | ~tdm_register_out_valid & be_buffer_out_last;
         assign be_buffer_out_ready = be_out_ready & ~tdm_register_out_valid;

      end else begin
         assign be_in_ready = 'b1;
         assign be_buffer_out_flit = 'b0;
         assign be_buffer_out_valid = 1'b0;
         assign be_buffer_out_last = 1'b0;

         assign tdm_out_valid = tdm_register_out_valid;
         assign be_out_valid = 1'b0;
         assign out_flit = tdm_register_out_flit;
         assign out_last = tdm_register_out_last;
      end
   endgenerate

endmodule // hybrid_noc_router_output
