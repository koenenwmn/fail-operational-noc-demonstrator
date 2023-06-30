/* Copyright (c) 2019 by the author(s)
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
 * This module provides the configuration information of the network
 * adapter to the software via memory mapped registers. It is compatible to its
 * OptimSoC equivalent.
 *
 *
 * Author(s):
 *   Stefan Wallentowitz <stefan.wallentowitz@tum.de>
 *   Alex Ostertag <ga76zox@mytum.de>
 */
import optimsoc_config::*;

module ni_config #(
   // CONFIG PARAMS
   parameter config_t CONFIG = 'x,
   parameter TILEID = 'x,
   parameter COREBASE = 'x
)(
   input clk,
   input rst,

   // Bus (generic)
   input [31:0]                  bus_addr,
   input                         bus_we,
   input                         bus_en,
   input [31:0]                  bus_data_in,
   output logic [31:0]           bus_data_out,
   output logic                  bus_ack,
   output logic                  bus_err
);

   // The addresses of the memory mapped registers
   localparam REG_TILEID   = 0;
   localparam REG_NUMTILES = 1;
   localparam REG_CONF   = 3;
   localparam REG_COREBASE = 4;
   localparam REG_DOMAIN_NUMCORES = 6;
   localparam REG_GMEM_SIZE = 7;
   localparam REG_GMEM_TILE = 8;
   localparam REG_LMEM_SIZE = 9;
   localparam REG_NUMCTS = 10;
   localparam REG_SEED = 11;

   localparam REG_CTLIST   = 10'h80;

   localparam REGBIT_CONF_MPSIMPLE = 0;
   localparam REGBIT_CONF_DMA      = 1;

   wire [15:0] ctlist_vector[0:63];
   reg [31:0]  seed;
   assign seed = 32'h0;

// -----------------------------------------------------------------------------
   genvar i;
   generate
      for (i = 0; i < 64; i = i + 1) begin : gen_ctlist_vector // array is indexed by the desired destination
         if (i < CONFIG.NUMCTS) begin
            // The entries of the ctlist_vector array are subranges from the parameter, where
            // the indexing is reversed (num_dests-i-1)!
            assign ctlist_vector[CONFIG.NUMCTS - i - 1] = CONFIG.CTLIST[i];
         end else begin
            // All other entries are unused and zero'ed.
            assign ctlist_vector[i] = 16'h0;
         end
      end
   endgenerate

   always_comb begin
      if(bus_en) begin
         if (bus_addr[11:9] == REG_CTLIST[9:7]) begin
            if (bus_addr[1]) begin
               bus_data_out = {16'h0,ctlist_vector[bus_addr[6:1]]};
               bus_ack = 1'b1;
               bus_err = 1'b0;
            end else begin
               bus_data_out = {ctlist_vector[bus_addr[6:1]],16'h0};
               bus_ack = 1'b1;
               bus_err = 1'b0;
            end
         end else begin
            case (bus_addr[11:2])
               REG_TILEID: begin
                  bus_data_out = TILEID;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_NUMTILES: begin
                  bus_data_out = CONFIG.NUMTILES;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_CONF: begin
                  bus_data_out = 32'h0;
                  bus_data_out[REGBIT_CONF_MPSIMPLE] = CONFIG.NA_ENABLE_MPSIMPLE;
                  bus_data_out[REGBIT_CONF_DMA] = CONFIG.NA_ENABLE_DMA;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_COREBASE: begin
                  bus_data_out = COREBASE;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_DOMAIN_NUMCORES: begin
                  bus_data_out = CONFIG.CORES_PER_TILE;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_GMEM_SIZE: begin
                  bus_data_out = CONFIG.GMEM_SIZE;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_GMEM_TILE: begin
                  bus_data_out = CONFIG.GMEM_TILE;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_LMEM_SIZE: begin
                  bus_data_out = CONFIG.LMEM_SIZE;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_NUMCTS: begin
                  bus_data_out = CONFIG.NUMCTS;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               REG_SEED: begin
                  bus_data_out = seed;
                  bus_ack = 1'b1;
                  bus_err = 1'b0;
               end
               default: begin
                  bus_data_out = 32'h0;
                  bus_ack = 1'b0;
                  bus_err = 1'b1;
               end
            endcase // case(bus_addr)
         end
      end else begin
         bus_data_out = 32'h0;
         bus_ack = 1'b0;
         bus_err = 1'b0;
      end
   end

endmodule //ni_config
