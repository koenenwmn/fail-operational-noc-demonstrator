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
 * This is a mesh topology hybrid network-on-chip. It generates the mesh with
 * routers in the X and the Y direction and generates all wiring.
 * The mesh has the option to instantiate fault injection modules (FIM) on all
 * links between routers and NIs and routers.
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 */

module hybrid_noc_mesh #(
   parameter FLIT_WIDTH = 32,
   parameter LUT_SIZE = 16,
   parameter REGISTER_STAGES = 1,
   parameter BUFFER_DEPTH_I = 8,
   parameter BUFFER_DEPTH_O = 2,
   parameter X = 2,
   parameter Y = 2,
   parameter CT_LINKS = 1,
   parameter PARITY_BITS = 0,
   parameter ENABLE_FDM = 0,
   parameter FAULTS_PERMANENT = 1,
   parameter ENABLE_FIM = 0,
   parameter ENABLE_DR = 0,         // Enables distributed routing using routing tables for X-Y-routing
   parameter NUM_BE_ENDPOINTS = 1,
   localparam NODES = X*Y
)(
   input clk,
   input rst,

   input [NODES*CT_LINKS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]   in_flit,
   input [NODES*CT_LINKS-1:0]                               in_last,
   input [NODES*CT_LINKS-1:0]                               tdm_in_valid,
   input [NODES*CT_LINKS-1:0]                               be_in_valid,
   output [NODES*CT_LINKS-1:0]                              be_in_ready,

   output [NODES*CT_LINKS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]  out_flit,
   output [NODES*CT_LINKS-1:0]                              out_last,
   output [NODES*CT_LINKS-1:0]                              tdm_out_valid,
   output [NODES*CT_LINKS-1:0]                              be_out_valid,
   input [NODES*CT_LINKS-1:0]                               be_out_ready,

   // Interface for writing to router LUTs.
   input [2:0]                                              lut_conf_data,
   input [2:0]                                              lut_conf_sel,
   input [$clog2(LUT_SIZE)-1:0]                             lut_conf_slot,
   input [$clog2(NODES)-1:0]                                config_node,
   input                                                    lut_conf_valid,

   // Inputs and outputs necessary for the noc_control_module
   input [NODES-1:0][4+(CT_LINKS*2)-1:0]                    fim_enable,
   output [NODES-1:0][4+(CT_LINKS)-1:0]                     out_error,
   output [NODES-1:0][4+(CT_LINKS*2)-1:0]                   tdm_util,
   output [NODES-1:0][4+(CT_LINKS*2)-1:0]                   be_util
);

   // ensure that parameters are set to allowed values
   initial begin
      if (ENABLE_FIM != 0 && ENABLE_FIM != 1) begin
         $fatal("hybrid_noc_mesh: ENABLE_FIM must be set to '0' or '1'.");
      end
   end

   // Those are indexes into the wiring arrays
   localparam NORTH  = 0;
   localparam EAST   = 1;
   localparam SOUTH  = 2;
   localparam WEST   = 3;
   localparam LOCAL  = 4;
   localparam PORTS  = 4 + CT_LINKS;

   // Table width for distributed routing. Does not consider multiple ct linkts.
   // That is handled with a special bit in the header.
   localparam TABLE_WIDTH = $clog2(LOCAL+1);

   genvar x, y, i;
   generate
      // Arrays of wires between the routers. Each router has a
      // pair of NoC wires per direction and below those are hooked
      // up.
      wire [NODES-1:0][PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]  node_in_flit;
      wire [NODES-1:0][PORTS-1:0]                              node_in_last;
      wire [NODES-1:0][PORTS-1:0]                              node_tdm_in_valid;
      wire [NODES-1:0][PORTS-1:0]                              node_be_in_valid;
      wire [NODES-1:0][PORTS-1:0]                              node_be_out_ready;

      wire [NODES-1:0][PORTS-1:0][PARITY_BITS+FLIT_WIDTH-1:0]  node_out_flit;
      wire [NODES-1:0][PORTS-1:0]                              node_out_last;
      wire [NODES-1:0][PORTS-1:0]                              node_tdm_out_valid;
      wire [NODES-1:0][PORTS-1:0]                              node_be_out_valid;
      wire [NODES-1:0][PORTS-1:0]                              node_be_in_ready;

      for (y = 0; y < Y; y++) begin : ydir
         for (x = 0; x < X; x++) begin : xdir
            // Utilization of the router input links
            for (i = 0; i < PORTS; i++) begin : util
               assign tdm_util[nodenum(x,y)][i] = node_tdm_out_valid[nodenum(x,y)][i];
               assign be_util[nodenum(x,y)][i] = node_be_out_valid[nodenum(x,y)][i];
            end

            for (i = 0; i < CT_LINKS; i++) begin : ct_links
               // Input links from NIs to routers
               if (ENABLE_FIM) begin : fim_in
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_in_flit (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][LOCAL+i]),
                     .flit_valid (tdm_in_valid[nodenum(x,y)*CT_LINKS+i] | be_in_valid[nodenum(x,y)*CT_LINKS+i]),
                     .in_flit    (in_flit[nodenum(x,y)*CT_LINKS+i]),
                     .out_flit   (node_in_flit[nodenum(x,y)][LOCAL+i])
                  );
               end else begin
                  assign node_in_flit[nodenum(x,y)][LOCAL+i] = in_flit[nodenum(x,y)*CT_LINKS+i];
               end
               assign node_in_last[nodenum(x,y)][LOCAL+i] = in_last[nodenum(x,y)*CT_LINKS+i];
               assign node_tdm_in_valid[nodenum(x,y)][LOCAL+i] = tdm_in_valid[nodenum(x,y)*CT_LINKS+i];
               assign node_be_in_valid[nodenum(x,y)][LOCAL+i] = be_in_valid[nodenum(x,y)*CT_LINKS+i];
               assign be_in_ready[nodenum(x,y)*CT_LINKS+i] = node_be_in_ready[nodenum(x,y)][LOCAL+i];

               // Output links from routers to NIs
               if (ENABLE_FIM) begin : fim_out
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_out_flit (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][LOCAL+CT_LINKS+i]),
                     .flit_valid (node_tdm_out_valid[nodenum(x,y)][LOCAL+i] | node_be_out_valid[nodenum(x,y)][LOCAL+i]),
                     .in_flit    (node_out_flit[nodenum(x,y)][LOCAL+i]),
                     .out_flit   (out_flit[nodenum(x,y)*CT_LINKS+i])
                  );
               end else begin
                  assign out_flit[nodenum(x,y)*CT_LINKS+i] = node_out_flit[nodenum(x,y)][LOCAL+i];
               end
               assign out_last[nodenum(x,y)*CT_LINKS+i] = node_out_last[nodenum(x,y)][LOCAL+i];
               assign tdm_out_valid[nodenum(x,y)*CT_LINKS+i] = node_tdm_out_valid[nodenum(x,y)][LOCAL+i];
               assign be_out_valid[nodenum(x,y)*CT_LINKS+i] = node_be_out_valid[nodenum(x,y)][LOCAL+i];
               assign node_be_out_ready[nodenum(x,y)][LOCAL+i] = be_out_ready[nodenum(x,y)*CT_LINKS+i];
               // Utilization of the CT output links
               assign tdm_util[nodenum(x,y)][LOCAL+CT_LINKS+i] = node_tdm_in_valid[nodenum(x,y)][LOCAL+i];
               assign be_util[nodenum(x,y)][LOCAL+CT_LINKS+i] = node_be_in_valid[nodenum(x,y)][LOCAL+i];
            end

            // Instantiate the router.
            hybrid_noc_router #(
               .FLIT_WIDTH(FLIT_WIDTH),
               .PORTS(PORTS),
               .LUT_SIZE(LUT_SIZE),
               .REGISTER_STAGES(REGISTER_STAGES),
               .BUFFER_DEPTH_I(BUFFER_DEPTH_I),
               .BUFFER_DEPTH_O(BUFFER_DEPTH_O),
               .PARITY_BITS(PARITY_BITS),
               .ENABLE_FDM(ENABLE_FDM),
               .FAULTS_PERMANENT(FAULTS_PERMANENT),
               .ENABLE_DR(ENABLE_DR),
               .CT_LINKS(CT_LINKS),
               .NUM_BE_ENDPOINTS(NUM_BE_ENDPOINTS),
               .TABLE_WIDTH(TABLE_WIDTH),
               .LOCAL(LOCAL),
               .DESTS(NODES),
               .ACTIVE_LINKS(active_links(x, y)),
               .ROUTES(genroutes(x,y)))
            u_router (
               .clk              (clk),
               .rst              (rst),
               .in_flit          (node_in_flit[nodenum(x,y)]),
               .in_last          (node_in_last[nodenum(x,y)]),
               .tdm_in_valid     (node_tdm_in_valid[nodenum(x,y)]),
               .be_in_valid      (node_be_in_valid[nodenum(x,y)]),
               .be_in_ready      (node_be_in_ready[nodenum(x,y)]),
               .out_flit         (node_out_flit[nodenum(x,y)]),
               .out_last         (node_out_last[nodenum(x,y)]),
               .tdm_out_valid    (node_tdm_out_valid[nodenum(x,y)]),
               .be_out_valid     (node_be_out_valid[nodenum(x,y)]),
               .be_out_ready     (node_be_out_ready[nodenum(x,y)]),
               .lut_conf_data    (lut_conf_data),
               .lut_conf_sel     (lut_conf_sel),
               .lut_conf_slot    (lut_conf_slot),
               .lut_conf_valid   (lut_conf_valid && (nodenum(x,y) == config_node)),
               .out_error        (out_error[nodenum(x,y)])
            );

            // The following are all the connections of the routers
            // in the four directions. If the router is on an outer
            // border, tie off (set to '0' for now).
            // If the FIM is enabled it is inserted in between the wires.
            // The flags are directly connected.
            if (y > 0) begin : north
               if (ENABLE_FIM) begin : fim_north
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_north (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][NORTH]),
                     .flit_valid (node_tdm_out_valid[northof(x,y)][SOUTH] | node_be_out_valid[northof(x,y)][SOUTH]),
                     .in_flit    (node_out_flit[northof(x,y)][SOUTH]),
                     .out_flit   (node_in_flit[nodenum(x,y)][NORTH])
                  );
               end else begin
                  assign node_in_flit[nodenum(x,y)][NORTH] = node_out_flit[northof(x,y)][SOUTH];
               end
               assign node_in_last[nodenum(x,y)][NORTH] = node_out_last[northof(x,y)][SOUTH];
               assign node_tdm_in_valid[nodenum(x,y)][NORTH] = node_tdm_out_valid[northof(x,y)][SOUTH];
               assign node_be_in_valid[nodenum(x,y)][NORTH] = node_be_out_valid[northof(x,y)][SOUTH];
               assign node_be_out_ready[nodenum(x,y)][NORTH] = node_be_in_ready[northof(x,y)][SOUTH];
            end else begin
               assign node_in_flit[nodenum(x,y)][NORTH] = 1'b0;
               assign node_in_last[nodenum(x,y)][NORTH] = 1'b0;
               assign node_tdm_in_valid[nodenum(x,y)][NORTH] = 1'b0;
               assign node_be_in_valid[nodenum(x,y)][NORTH] = 1'b0;
               assign node_be_out_ready[nodenum(x,y)][NORTH] = 1'b1;
            end

            if (y < Y-1) begin : south
               if (ENABLE_FIM) begin : fim_south
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_south (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][SOUTH]),
                     .flit_valid (node_tdm_out_valid[southof(x,y)][NORTH] | node_be_out_valid[southof(x,y)][NORTH]),
                     .in_flit    (node_out_flit[southof(x,y)][NORTH]),
                     .out_flit   (node_in_flit[nodenum(x,y)][SOUTH])
                  );
               end else begin
                  assign node_in_flit[nodenum(x,y)][SOUTH] = node_out_flit[southof(x,y)][NORTH];
               end
               assign node_in_last[nodenum(x,y)][SOUTH] = node_out_last[southof(x,y)][NORTH];
               assign node_tdm_in_valid[nodenum(x,y)][SOUTH] = node_tdm_out_valid[southof(x,y)][NORTH];
               assign node_be_in_valid[nodenum(x,y)][SOUTH] = node_be_out_valid[southof(x,y)][NORTH];
               assign node_be_out_ready[nodenum(x,y)][SOUTH] = node_be_in_ready[southof(x,y)][NORTH];
            end else begin
               assign node_in_flit[nodenum(x,y)][SOUTH] = 1'b0;
               assign node_in_last[nodenum(x,y)][SOUTH] = 1'b0;
               assign node_tdm_in_valid[nodenum(x,y)][SOUTH] = 1'b0;
               assign node_be_in_valid[nodenum(x,y)][SOUTH] = 1'b0;
               assign node_be_out_ready[nodenum(x,y)][SOUTH] = 1'b1;
            end

            if (x > 0) begin : west
               if (ENABLE_FIM) begin : fim_west
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_west (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][WEST]),
                     .flit_valid (node_tdm_out_valid[westof(x,y)][EAST] | node_be_out_valid[westof(x,y)][EAST]),
                     .in_flit    (node_out_flit[westof(x,y)][EAST]),
                     .out_flit   (node_in_flit[nodenum(x,y)][WEST])
                  );
               end else begin
                  assign node_in_flit[nodenum(x,y)][WEST] = node_out_flit[westof(x,y)][EAST];
               end
               assign node_in_last[nodenum(x,y)][WEST] = node_out_last[westof(x,y)][EAST];
               assign node_tdm_in_valid[nodenum(x,y)][WEST] = node_tdm_out_valid[westof(x,y)][EAST];
               assign node_be_in_valid[nodenum(x,y)][WEST] = node_be_out_valid[westof(x,y)][EAST];
               assign node_be_out_ready[nodenum(x,y)][WEST] = node_be_in_ready[westof(x,y)][EAST];
            end else begin
               assign node_in_flit[nodenum(x,y)][WEST] = 1'b0;
               assign node_in_last[nodenum(x,y)][WEST] = 1'b0;
               assign node_tdm_in_valid[nodenum(x,y)][WEST] = 1'b0;
               assign node_be_in_valid[nodenum(x,y)][WEST] = 1'b0;
               assign node_be_out_ready[nodenum(x,y)][WEST] = 1'b1;
            end

            if (x < X-1) begin : east
               if (ENABLE_FIM) begin : fim_east
                  fault_injection_module #(
                     .FLIT_WIDTH(FLIT_WIDTH+PARITY_BITS))
                  u_fim_east (
                     .clk        (clk),
                     .rst        (rst),
                     .enable     (fim_enable[nodenum(x,y)][EAST]),
                     .flit_valid (node_tdm_out_valid[eastof(x,y)][WEST] | node_be_out_valid[eastof(x,y)][WEST]),
                     .in_flit    (node_out_flit[eastof(x,y)][WEST]),
                     .out_flit   (node_in_flit[nodenum(x,y)][EAST])
                  );
               end else begin
                  assign node_in_flit[nodenum(x,y)][EAST] = node_out_flit[eastof(x,y)][WEST];
               end
               assign node_in_last[nodenum(x,y)][EAST] = node_out_last[eastof(x,y)][WEST];
               assign node_tdm_in_valid[nodenum(x,y)][EAST] = node_tdm_out_valid[eastof(x,y)][WEST];
               assign node_be_in_valid[nodenum(x,y)][EAST] = node_be_out_valid[eastof(x,y)][WEST];
               assign node_be_out_ready[nodenum(x,y)][EAST] = node_be_in_ready[eastof(x,y)][WEST];
            end else begin
               assign node_in_flit[nodenum(x,y)][EAST] = 1'b0;
               assign node_in_last[nodenum(x,y)][EAST] = 1'b0;
               assign node_tdm_in_valid[nodenum(x,y)][EAST] = 1'b0;
               assign node_be_in_valid[nodenum(x,y)][EAST] = 1'b0;
               assign node_be_out_ready[nodenum(x,y)][EAST] = 1'b1;
            end
         end
      end
   endgenerate

   // Get the node number
   function integer nodenum(input integer x,input integer y);
      nodenum = x+y*X;
   endfunction // nodenum

   // Get the node north of position
   function integer northof(input integer x,input integer y);
      northof = x+(y-1)*X;
   endfunction // northof

   // Get the node east of position
   function integer eastof(input integer x,input integer y);
      eastof  = (x+1)+y*X;
   endfunction // eastof

   // Get the node south of position
   function integer southof(input integer x,input integer y);
      southof = x+(y+1)*X;
   endfunction // southof

   // Get the node west of position
   function integer westof(input integer x,input integer y);
      westof = (x-1)+y*X;
   endfunction // westof

   // Create bitvector with active links
   function [4 + CT_LINKS - 1:0] active_links(input integer x, input integer y);
      integer i;
      active_links = '0;
      if (y > 0)
         active_links[0] = 1'b1;
      if (x < X-1)
         active_links[1] = 1'b1;
      if (y < Y-1)
         active_links[2] = 1'b1;
      if (x > 0)
         active_links[3] = 1'b1;
      for ( i = 0; i < CT_LINKS; i++)
         active_links[4+i] = 1'b1;
   endfunction

   // This generates the lookup table for each individual node in case
   // distributed routing is used
   function [NODES-1:0][TABLE_WIDTH-1:0] genroutes(input integer x, input integer y);
      integer yd,xd;
      integer nd;
      logic [$clog2(PORTS+1)-1:0] d;

      genroutes = {NODES*TABLE_WIDTH{1'b1}};

      for (yd = 0; yd < Y; yd++) begin
         for (xd = 0; xd < X; xd++) begin : inner_loop
            nd = nodenum(xd,yd);
            d = {$clog2(PORTS+1){1'b1}};
            if ((xd==x) && (yd==y)) begin
               d = LOCAL;
            end else if (xd==x) begin
               if (yd<y) begin
                  d = NORTH;
               end else begin
                  d = SOUTH;
               end
            end else begin
               if (xd<x) begin
                  d = WEST;
               end else begin
                  d = EAST;
               end
            end // else: !if(xd==x)
            genroutes[nd] = d;
         end
      end
   endfunction

endmodule // hybrid_noc_mesh
