/* Copyright (c) 2018-2020 by the author(s)
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
 * This is a hybrid NoC router. It has a configurable number of input and output
 * ports, and a configurable LUT size.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_router #(
   parameter FLIT_WIDTH = 32,
   parameter PORTS = 5,
   parameter LUT_SIZE = 16,
   parameter REGISTER_STAGES = 1,
   parameter BUFFER_DEPTH_I = 4,
   parameter BUFFER_DEPTH_O = 2,
   parameter PARITY_BITS = 0,
   parameter ENABLE_FDM = 0,
   parameter FAULTS_PERMANENT = 1,
   parameter ENABLE_DR = 0,
   parameter CT_LINKS = 1,
   parameter NUM_BE_ENDPOINTS = 1,
   parameter TABLE_WIDTH = 0,
   parameter LOCAL = 0,
   parameter DESTS = 0,
   parameter [PORTS-1:0] ACTIVE_LINKS = '1,
   parameter [DESTS*TABLE_WIDTH-1:0] ROUTES = {DESTS*TABLE_WIDTH{1'b1}},
   localparam NUM_ACTIVE_LINKS = num_active_links(),
   localparam BE_PORTS = PORTS - CT_LINKS + NUM_BE_ENDPOINTS,
   localparam NUM_BE_PORTS = NUM_ACTIVE_LINKS - CT_LINKS + NUM_BE_ENDPOINTS
)(
   input clk,
   input rst,

   input [PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]   in_flit,
   input [PORTS-1:0]                               in_last,
   input [PORTS-1:0]                               tdm_in_valid,
   input [PORTS-1:0]                               be_in_valid,
   output [PORTS-1:0]                              be_in_ready,

   output [PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]  out_flit,
   output [PORTS-1:0]                              out_last,
   output [PORTS-1:0]                              tdm_out_valid,
   output [PORTS-1:0]                              be_out_valid,
   input [PORTS-1:0]                               be_out_ready,

   // Interface for writing to LUT.
   // Each output port has it's own LUT determining which input to forward.
   input [$clog2(PORTS+1)-1:0]                     lut_conf_data,
   input [$clog2(PORTS)-1:0]                       lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]                    lut_conf_slot,
   input                                           lut_conf_valid,

   // Interface for signaling a fault to the control network
   output [PORTS-1:0]                              out_error
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (REGISTER_STAGES != 1 && REGISTER_STAGES != 2) begin
         $fatal("hybrid_noc_router: REGISTER_STAGES must be set to '1' or '2'.");
      end else if (ENABLE_FDM != 0 && ENABLE_FDM != 1) begin
         $fatal("hybrid_noc_router: ENABLE_FDM must be set to '0' or '1'.");
      end else if (NUM_BE_ENDPOINTS != 1 && NUM_BE_ENDPOINTS != 2) begin
         $fatal("hybrid_noc_router: NUM_BE_ENDPOINTS must be set to '1' or '2'.");
      end else if (CT_LINKS != 1 && CT_LINKS != 2) begin
         $fatal("hybrid_noc_router: CT_LINKS must be set to '1' or '2'.");
      end
   end

   // The "switch" is just wiring (all logic is in input and
   // output). All inputs generate their requests for the outputs and
   // the output arbitrate between the input requests.

   wire [PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]             tdm_switch_in_flit;
   wire [PORTS-1:0]                                         tdm_switch_in_valid;
   wire [PORTS-1:0]                                         tdm_switch_in_last;
   wire [PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]             be_switch_in_flit;
   wire [PORTS-1:0][PORTS-1:0]                              be_switch_in_valid;
   wire [PORTS-1:0]                                         be_switch_in_last;
   wire [PORTS-1:0][PORTS-1:0]                              be_switch_in_ready;

   // Outputs are fully wired to receive all input flits.
   wire [PORTS-1:0][PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]        tdm_switch_out_flit;
   wire [PORTS-1:0][PORTS-1:0]                                    tdm_switch_out_valid;
   wire [PORTS-1:0][PORTS-1:0]                                    tdm_switch_out_last;
   wire [PORTS-1:0][NUM_BE_PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0] be_switch_out_flit;
   wire [PORTS-1:0][NUM_BE_PORTS-1:0]                             be_switch_out_valid;
   wire [PORTS-1:0][NUM_BE_PORTS-1:0]                             be_switch_out_last;
   wire [PORTS-1:0][NUM_BE_PORTS-1:0]                             be_switch_out_ready;

   // Wiring of FDM out_error
   wire [PORTS-1:0] fdm_out_error;
   assign out_error = fdm_out_error;

   genvar   i, o;
   generate
      // The TDM input
      if (REGISTER_STAGES == 1) begin
         for (i = 0; i < PORTS; i++) begin : tdm_input_wiring
            // For TDM, simply wire the inputs to the output stages
            assign tdm_switch_in_flit[i] = in_flit[i];
            assign tdm_switch_in_valid[i] = tdm_in_valid[i];
            assign tdm_switch_in_last[i] = in_last[i];
         end // block: tdm_input_wiring
      end else begin
         for (i = 0; i < PORTS; i++) begin : tdm_inputs
            // The input stages
            register_stage #(
               .FLIT_WIDTH(PARITY_BITS+FLIT_WIDTH),
               .FLAGS(2))
            u_tdm_input_register (
               .clk        (clk),
               .rst        (rst),
               .in_flit    (in_flit[i]),
               .in_flags   ({tdm_in_valid[i], in_last[i]}),
               .out_flit   (tdm_switch_in_flit[i]),
               .out_flags  ({tdm_switch_in_valid[i], tdm_switch_in_last[i]})
            );
         end // block: tdm_inputs
      end

      // The BE input
      for (i = 0; i < PORTS; i++) begin : be_inputs
         if (ACTIVE_LINKS[i] && (i < PORTS-1 || CT_LINKS == NUM_BE_ENDPOINTS)) begin
            hybrid_noc_router_input #(
               .FLIT_WIDTH(FLIT_WIDTH),
               .PORTS(PORTS),
               .INPUT_ID(i),
               .DEPTH(BUFFER_DEPTH_I),
               .ENABLE_DR(ENABLE_DR),
               .TABLE_WIDTH(TABLE_WIDTH),
               .LOCAL(LOCAL),
               .DESTS(DESTS),
               .ROUTES(ROUTES))
            u_be_input (
               .clk        (clk),
               .rst        (rst),
               .in_flit    (in_flit[i][0 +: FLIT_WIDTH]),
               .in_valid   (be_in_valid[i]),
               .in_last    (in_last[i]),
               .in_ready   (be_in_ready[i]),
               .out_flit   (be_switch_in_flit[i][0 +: FLIT_WIDTH]),
               .out_valid  (be_switch_in_valid[i]),
               .out_last   (be_switch_in_last[i]),
               .out_ready  (be_switch_in_ready[i])
            );

            // Hard-wire the "parity bits" to '0' for the BE flits
            if (PARITY_BITS != 0) begin
               assign be_switch_in_flit[i][FLIT_WIDTH +: PARITY_BITS] = {PARITY_BITS{1'b0}};
            end
         end else begin
            assign be_in_ready[i] = '1;
            assign be_switch_in_flit[i][0 +: FLIT_WIDTH] = '0;
            assign be_switch_in_valid[i] = '0;
            assign be_switch_in_last[i] = '0;
         end
      end // block: be_inputs

      if (ENABLE_FDM) begin
         for (i = 0; i < PORTS; i++) begin : fdms
            // The input Fault Detection Modules
            fault_detection_module #(
               .FLIT_WIDTH(FLIT_WIDTH),
               .ROUTER_STAGES(REGISTER_STAGES),
               .FAULTS_PERMANENT(FAULTS_PERMANENT))
            u_fdm (
               .clk        (clk),
               .rst        (rst),
               .in_flit    (in_flit[i][0 +: FLIT_WIDTH]),
               .in_valid   (tdm_in_valid[i]),
               .in_parity  (in_flit[i][FLIT_WIDTH +: PARITY_BITS]),
               .out_error  (fdm_out_error[i])
            );
         end // block: fdms
      end else begin
         // If no fault detection is active, suppose no fault on the link happened
         assign fdm_out_error = {PORTS{1'b0}};
      end

      // The switching wires
      for (o = 0; o < PORTS; o++) begin
         for (i = 0; i < PORTS; i++) begin
            assign tdm_switch_out_flit[o][i] = tdm_switch_in_flit[i];
            assign tdm_switch_out_valid[o][i] = tdm_switch_in_valid[i] & ~fdm_out_error[i];
            assign tdm_switch_out_last[o][i] = tdm_switch_in_last[i];
         end
      end
      for (o = 0; o < PORTS; o++) begin
         if (ACTIVE_LINKS[o]) begin
            for (i = 0; i < BE_PORTS; i++) begin
               if (ACTIVE_LINKS[i]) begin
                  assign be_switch_out_flit[o][be_idx(i)] = be_switch_in_flit[i];
                  assign be_switch_out_valid[o][be_idx(i)] = be_switch_in_valid[i][o];
                  assign be_switch_out_last[o][be_idx(i)] = be_switch_in_last[i];
               end
            end
         end
      end
      for (i = 0; i < PORTS; i++) begin
         for (o = 0; o < PORTS; o++) begin
            if (ACTIVE_LINKS[i] && ACTIVE_LINKS[o] && i < BE_PORTS && o < BE_PORTS) begin
               assign be_switch_in_ready[i][o] = be_switch_out_ready[o][be_idx(i)];
            end else begin
               assign be_switch_in_ready[i][o] = 1'b1;
            end
         end
      end

      for (o = 0; o < PORTS; o++) begin :  outputs
         if (ACTIVE_LINKS[o]) begin
            // The output stages
            hybrid_noc_router_output #(
               .FLIT_WIDTH(PARITY_BITS+FLIT_WIDTH),
               .PORTS(PORTS),
               .LUT_SIZE(LUT_SIZE),
               .BE_ENABLED((o < BE_PORTS) ? 1 : 0),
               .BE_PORTS(NUM_BE_PORTS),
               .OUTPUT_ID(o),
               .BUFFER_DEPTH(BUFFER_DEPTH_O))
            u_output (
               .clk              (clk),
               .rst              (rst),
               .tdm_in_flit      (tdm_switch_out_flit[o]),
               .tdm_in_valid     (tdm_switch_out_valid[o]),
               .tdm_in_last      (tdm_switch_out_last[o]),
               .be_in_flit       (be_switch_out_flit[o]),
               .be_in_valid      (be_switch_out_valid[o]),
               .be_in_last       (be_switch_out_last[o]),
               .be_in_ready      (be_switch_out_ready[o]),
               .out_flit         (out_flit[o]),
               .out_last         (out_last[o]),
               .tdm_out_valid    (tdm_out_valid[o]),
               .be_out_valid     (be_out_valid[o]),
               .be_out_ready     (be_out_ready[o]),
               .lut_conf_data    (lut_conf_data),
               .lut_conf_sel     (lut_conf_sel),
               .lut_conf_slot    (lut_conf_slot),
               .lut_conf_valid   (lut_conf_valid)
            );
         end else begin
            //assign be_switch_out_ready[o] = '1;
            assign out_flit[o] = '0;
            assign out_last[o] = '0;
            assign tdm_out_valid[o] = '0;
            assign be_out_valid[o] = '0;
         end
      end
   endgenerate

   // Determine the BE index of a port
   function integer be_idx(input integer port);
      integer i;
      be_idx = 0;
      for (i = 0; i < port; i++) begin
         if (ACTIVE_LINKS[i]) begin
            be_idx = be_idx + 1;
         end
      end
   endfunction

   // Determine number of active links
   function integer num_active_links();
      integer i;
      num_active_links = 0;
      for (i = 0; i < PORTS; i++) begin
         if (ACTIVE_LINKS[i]) begin
            num_active_links = num_active_links + 1;
         end
      end
   endfunction
endmodule // hybrid_noc_router
