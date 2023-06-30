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
 * This module holds a single BE (Best Effort) Endpoint for the Hybrid NoC. Data
 * added to the output queue will be inserted into the NoC whenever no TDM data
 * is available. Data from the NoC that is assigned to this channel will be
 * added to the input queue and an interrupt will be issued once a full packet
 * has been received.
 * The Endpoint also handles control messages to indicate to other tiles
 * whether it is enabled or not.
 *
 * TODO: - include status register functionality
 *       - include write error functionality (in case a packet is larger than
 *         the buffer, otherwise there will be a deadlock)
 *       - noc_in_rdy: currently, ctrl messages will not be handled if the input
 *         dualclk FIFO is full. This should be reviewed.
 *
 * Author(s):
 *   Alex Ostertag <ga76zox@mytum.de>
 *   Max Koenen <max.koenen@tum.de>
 */

module ni_be_endpoint #(
   parameter FLIT_WIDTH = 32,
   parameter DEPTH = 16,
   parameter MAX_LEN = 8,
   parameter ENABLE_DR = 0,         // Use distributed routing
   parameter ENABLE_CTRL_MSG = 1,   // Enable handling of control messages
   localparam MAX_WIDTH = $clog2(MAX_LEN+1),
   localparam SPECIFIC_START = 24,
   localparam SPECIFIC_WIDTH = 5,
   localparam NODE_ID_WIDTH = 10
)(
   input clk_bus,
   input clk_noc,
   input rst_bus,
   input rst_noc,

   output [FLIT_WIDTH-1:0]       noc_out_flit,
   output                        noc_out_last,
   output                        noc_out_valid,
   input                         noc_out_ready,

   input [FLIT_WIDTH-1:0]        noc_in_flit,
   input                         noc_in_last,
   input                         noc_in_valid,
   output                        noc_in_ready,

   // Bus Side (generic)
   input [31:0]                  bus_addr,
   input                         bus_we,
   input                         bus_en,
   input [31:0]                  bus_data_in,
   output logic [31:0]           bus_data_out,
   output logic                  bus_ack,
   output                        bus_err,

   output                        irq
);

   // Ensure that parameters are set to allowed values
   initial begin
      if (FLIT_WIDTH != 32) begin
         $fatal("Currently FLIT_WIDTH must be set to 32.");
      end
   end

   // Bus Addr Selects: Show selected addr and that bus is enabled
   wire                    bus_addr_0_sel;
   wire                    bus_addr_4_sel;

   // Addr 0, W: Write packets to the Out Queue
   wire                    out_queue_in_last;
   wire                    out_queue_in_valid;
   wire                    out_queue_in_ready;
   wire [FLIT_WIDTH-1:0]   out_queue_out_flit;
   wire                    out_queue_out_last;
   wire                    out_queue_out_valid;

   reg [MAX_WIDTH-1:0]     wr_size;

   wire [FLIT_WIDTH-1:0]   out_dualclk_out_flit;
   wire                    out_dualclk_out_last;
   wire                    out_dualclk_full;
   wire                    out_dualclk_empty;

   // Addr 0, R: Read NoC packets from the In Queue
   wire                    in_dualclk_full;
   wire                    in_dualclk_empty;

   wire [FLIT_WIDTH-1:0]   in_dualclk_in_flit;
   wire [FLIT_WIDTH-1:0]   in_queue_in_flit;
   wire                    in_queue_in_last;
   wire                    in_queue_in_ready;
   wire [31:0]             in_queue_out_flit;
   wire [MAX_WIDTH-1:0]    in_queue_out_size;
   wire                    in_queue_out_valid;
   wire                    in_queue_rd_en;

   reg [MAX_WIDTH-1:0]     rd_size;

   // Addr 4: Enable/Disable Interface, Read Status Register
   reg                     if_enabled;
   reg                     if_status;
   // Helper register to only activate/deactivate between two packets
   reg                     if_req_enabled;

   // Clock domain crossing for enable signal
   (* ASYNC_REG = "true" *) reg [1:0] if_enabled_cdc;
   always_ff @(posedge clk_noc)
      {if_enabled_cdc[1], if_enabled_cdc[0]} <= {if_enabled_cdc[0], if_enabled};

   // For control message support
   wire                    in_is_ctrl_msg;
   wire                    noc_out_mux_ctrl;

//------------------------------------------------------------------------------
   /*
   * +------+---+------------------------+
   * | 0x0  | R | Read from Ingress FIFO |
   * +------+---+------------------------+
   * |      | W | Write to Egress FIFO   |
   * +------+---+------------------------+
   * | 0x4  | W | Enable interface       |
   * +------+---+------------------------+
   * |      | R | Status                 |
   * +------+---+------------------------+
   *
   */
   // Bus Addr Selects: Show selected address and that bus is enabled
   assign bus_addr_0_sel = (bus_addr[5:2] == 4'h0) & bus_en;
   assign bus_addr_4_sel = (bus_addr[5:2] == 4'h1) & bus_en;

   // Bus Outputs: Data_out, Ack, Error
   always_comb begin
      bus_data_out = 32'h0;
      bus_ack = 1'b0;
      if(bus_addr_0_sel) begin
         if(bus_we) begin
            // Only acknowledge if buffer is ready
            if (out_queue_in_ready) begin
               bus_ack = 1'b1;
            end
         end else begin
            // Only read from buffer if EP is enabled
            if (if_enabled) begin
               // Read a packet from the In Queue
               // First read the size of the packet, afterwards the flits
               bus_data_out = (rd_size == 0) ? in_queue_out_size : in_queue_out_flit;
               bus_ack = 1'b1;
            end
         end
      end else if(bus_addr_4_sel) begin
         bus_data_out = bus_we ? 32'h0 : {31'h0, if_status};
         bus_ack = 1'b1;
      end
   end
   // Issue a bus error, if the bus is enabled but the adress doesn't match
   assign bus_err = bus_en & ~(bus_addr_0_sel | bus_addr_4_sel);
   // Issue an interrupt, whenever a full packet is available in the In Queue
   // and the endpoint has been activated. If the endpoint is not enabled the
   // packet will be drained.
   assign irq = in_queue_out_valid & if_enabled & if_req_enabled;

//------------------------------------------------------------------------------
   // Addr 0, W: Write Packets to the Out Queue
   // First the Size of the packet is written on the bus.
   // If the packet won't fit in the queue, the packet is dismissed.
   // Packets are then forwarded from the Out Queue to the Out Dualclk Fifo,
   // to cross clock domains.

   // The Out Queue is a small initial buffer for egress messages.
   // It is fully inside the Bus Clockdomain.
   noc_buffer #(
      .DEPTH(1 << $clog2(MAX_LEN)),
      .FLIT_WIDTH(FLIT_WIDTH),
      .FULLPACKETVALID(1))
   u_out_queue(
      .clk              (clk_bus),
      .rst              (rst_bus),
      .in_flit          (bus_data_in),
      .in_last          (out_queue_in_last),
      .in_valid         (out_queue_in_valid),
      .in_ready         (out_queue_in_ready),
      .packet_size      (),
      .out_flit         (out_queue_out_flit),
      .out_last         (out_queue_out_last),
      .out_valid        (out_queue_out_valid),
      .out_ready        (~out_dualclk_full)
   );

   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         wr_size <= 0;
      end else begin
         // Wr_size counts down, how many flits are written to the Out Queue.
         if(bus_addr_0_sel & bus_we & out_queue_in_ready) begin
            if(wr_size == 0) begin
               wr_size <= bus_data_in[MAX_WIDTH-1:0];
            end else begin
               wr_size <= wr_size - 1;
            end
         end else begin
            wr_size <= wr_size;
         end
      end
   end

   assign out_queue_in_valid = (wr_size != 0) & bus_addr_0_sel & bus_we;
   assign out_queue_in_last = (wr_size == 1);

   // The Out Dualclk Fifo is a buffer, used to cross the clockdomains from the
   // Bus Side to the NoC Side.
   // Available Flits are always forwarded to this buffer when it's not full.
   fifo_dualclock_fwft #(
      .WIDTH(FLIT_WIDTH+1),
      .DEPTH(DEPTH))
   u_out_dualclk (
      .wr_clk     (clk_bus),
      .wr_rst     (rst_bus),
      .wr_en      (out_queue_out_valid),
      .din        ({out_queue_out_last, out_queue_out_flit}),

      .rd_clk     (clk_noc),
      .rd_rst     (rst_noc),
      .rd_en      (noc_out_ready & ~noc_out_mux_ctrl),
      .dout       ({out_dualclk_out_last, out_dualclk_out_flit}),

      .full       (out_dualclk_full),
      .prog_full  (),
      .empty      (out_dualclk_empty),
      .prog_empty ()
   );

//------------------------------------------------------------------------------
   // Addr 0, R: Read NoC Packets from the In Queue

   // The In Dualclk Fifo is a buffer, used to cross the clockdomains from the
   // NoC Side to the Bus Side.
   // Available Flits are always forwarded to the In Queue when it's not full.
   assign noc_in_ready = ~in_dualclk_full;
   fifo_dualclock_fwft #(
      .WIDTH(FLIT_WIDTH+1),
      .DEPTH(DEPTH))
   u_in_dualclk (
      .wr_clk     (clk_noc),
      .wr_rst     (rst_noc),
      .wr_en      (noc_in_valid & ~in_is_ctrl_msg),
      .din        ({noc_in_last, in_dualclk_in_flit}),

      .rd_clk     (clk_bus),
      .rd_rst     (rst_bus),
      .rd_en      (in_queue_in_ready & ~in_dualclk_empty),
      .dout       ({in_queue_in_last, in_queue_in_flit}),

      .full       (in_dualclk_full),
      .prog_full  (),
      .empty      (in_dualclk_empty),
      .prog_empty ()
   );

   // The In Queue is a small final buffer for ingress flits before they are
   // read via the bus.
   // It is fully inside the Bus Clockdomain.
   noc_buffer #(
      .DEPTH(1 << $clog2(MAX_LEN)),
      .FLIT_WIDTH(FLIT_WIDTH),
      .FULLPACKET(1))
   u_in_queue(
      .clk              (clk_bus),
      .rst              (rst_bus),
      .in_flit          (in_queue_in_flit),
      .in_last          (in_queue_in_last),
      .in_valid         (in_queue_in_ready & ~in_dualclk_empty),
      .in_ready         (in_queue_in_ready),
      .packet_size      (in_queue_out_size),
      .out_flit         (in_queue_out_flit),
      .out_last         (),
      .out_valid        (in_queue_out_valid),
      .out_ready        (in_queue_rd_en)
   );

   // Rd_size counts down, how many flits are read from the In Queue via the bus.
   // It is set to the size of the waiting packet inside the In Queue,
   // once the bus triggers a read command.
   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         rd_size <= 0;
      end else begin
         if(in_queue_out_valid & ((bus_addr_0_sel & ~bus_we) | ~if_enabled)) begin
            rd_size <= (rd_size == 0) ? in_queue_out_size : (rd_size - 1);
         end else begin
            rd_size <= rd_size;
         end
      end
   end
   assign in_queue_rd_en = (rd_size != 0) & ((bus_addr_0_sel & ~bus_we) | ~if_enabled);

//------------------------------------------------------------------------------
   // Addr 4: Enable/Disable Interface, Read Status Register
   // The module is only activated/deactivated in between packets
   always_ff @(posedge clk_bus) begin
      if(rst_bus) begin
         if_enabled <= 0;
         if_req_enabled <= 0;
         if_status <= 1;
      end else begin
         // Only update 'if_enabled' if there is no packet waiting to be read or
         // the last flit of a packet has been read.
         if_enabled <= (~in_queue_out_valid |
                        (in_queue_rd_en & (rd_size == 1)) |
                        ((rd_size == 0) & ~bus_addr_0_sel)) ? if_req_enabled : if_enabled;
         if_req_enabled <= (bus_addr_4_sel & bus_we) ? bus_data_in[0] : if_req_enabled;
         if_status <= if_status;
      end
   end

//------------------------------------------------------------------------------
   // Handle Control Messages
   // Packet Header:
   //    [3bit: Class, 5bit: class specific, 24bit: Source Routing]
   // Alternative for distributed routing:
   //    [3bit: Class, 9bit: class specific, 10bit: source, 10bit destination]
   //
   // The Endpoint can handle control messages to indicate whether it is enabled
   // or not to other Tiles. These control messages are single flit packets of
   // packet class 3'b111. A request message is marked by a '0' in the class
   // specific field, the answer is sent with '1' in the class specific field.
   // Once a control message request is recognized, an answer is generated in
   // hardware (if the endpoint has been enabled) and sent through the NoC on
   // the next possible occasion. If the endpoint has not been enabled, the
   // message is dismissed.
   // Packets that are currently output to the NoC are not interrupted by this.

   generate
      if (ENABLE_CTRL_MSG) begin

         // Handle Control Messages
         reg                     next_is_header;
         wire [FLIT_WIDTH-1:0]   ctrl_msg_responce;
         reg                     out_ctrl_msg_pending;
         reg [FLIT_WIDTH-1:0]    out_ctrl_msg;
         reg                     noc_out_mux_ctrl_fixed;

         // Indicates a control message was received by identifying the packet class.
         // Only Header flits can be control messages.
         assign in_is_ctrl_msg = next_is_header & noc_in_valid & (noc_in_flit[FLIT_WIDTH-1:FLIT_WIDTH-3] == 3'b111) & (noc_in_flit[SPECIFIC_START +: SPECIFIC_WIDTH] == 0);

         if (ENABLE_DR) begin
            // For distributed routing, switch source and destination ids for control message response
            // bit 28 determines the endpoint
            assign ctrl_msg_responce = {3'b111, 5'b00001, noc_in_flit[23], 3'b000, noc_in_flit[0 +: NODE_ID_WIDTH], noc_in_flit[NODE_ID_WIDTH +: NODE_ID_WIDTH]};
            // For normal messages, simply forward header flit to ingress FWFT FIFO
            assign in_dualclk_in_flit = noc_in_flit;
         end else begin
            // For source routing, generate reverse path
            wire [FLIT_WIDTH-9:0] source_routing_reverse_path;
            genvar i;
            for(i=0; i < FLIT_WIDTH-8; i++) begin
               assign source_routing_reverse_path[i] = noc_in_flit[FLIT_WIDTH-9-i];
            end
            // Send control message back along the reversed path. Beware of
            // potential deadlock situation.
            assign ctrl_msg_responce = {3'b111, 5'b00001, source_routing_reverse_path};
            // For normal messages, reverse path for header flit to simplify
            // finding the source.
            assign in_dualclk_in_flit = next_is_header ? {noc_in_flit[FLIT_WIDTH-1 -: 8], source_routing_reverse_path} : noc_in_flit;
         end


         always_ff @(posedge clk_noc) begin
            if(rst_noc) begin
               next_is_header <= 1;
               out_ctrl_msg <= 0;
               out_ctrl_msg_pending <= 0;
               noc_out_mux_ctrl_fixed <= 0;
            end else begin
               // Next_is_header indicates, that the next incoming flit will be a header
               if(noc_in_valid & noc_in_ready) begin
                  next_is_header <= noc_in_last ? 1'b1 : 1'b0;
               end else begin
                  next_is_header <= next_is_header;
               end
               // Build a control message answer, when a control message is received.
               // This answer is stored until it can be sent out.
               // If any other control messages are received until then, they are dismissed.
               if(in_is_ctrl_msg & (~out_ctrl_msg_pending | noc_out_mux_ctrl)) begin
                  out_ctrl_msg <= ctrl_msg_responce;
               end else begin
                  out_ctrl_msg <= out_ctrl_msg;
               end
               // Out_ctrl_msg_pending indicates, that a control message answer is
               // waiting to be sent. It is cleared once the answer is sent to the NoC.
               // Answers are only sent, if the endpoint has been enabled.
               if(in_is_ctrl_msg & if_enabled_cdc[1]) begin
                  out_ctrl_msg_pending <= 1;
               end else if(noc_out_mux_ctrl) begin
                  out_ctrl_msg_pending <= 0;
               end else begin
                  out_ctrl_msg_pending <= out_ctrl_msg_pending;
               end
               // The NoC Output MUX can only be changed inbetween packages,
               // not while a packet is transmitted.
               if(noc_out_valid & noc_out_ready) begin
                  noc_out_mux_ctrl_fixed <= ~noc_out_last;
               end else begin
                  noc_out_mux_ctrl_fixed <= noc_out_mux_ctrl_fixed;
               end
            end
         end

         // MUX NoC Output to either a control message answer or regular packets

         assign noc_out_mux_ctrl = ~noc_out_mux_ctrl_fixed & out_ctrl_msg_pending;
         assign noc_out_flit = noc_out_mux_ctrl ? out_ctrl_msg : out_dualclk_out_flit;
         assign noc_out_last = noc_out_mux_ctrl | out_dualclk_out_last;
         assign noc_out_valid = noc_out_mux_ctrl | ~out_dualclk_empty;
      end else begin
         assign in_is_ctrl_msg = 1'b0;
         assign noc_out_mux_ctrl = 1'b0;
         assign noc_out_flit = out_dualclk_out_flit;
         assign noc_out_last = out_dualclk_out_last;
         assign noc_out_valid = ~out_dualclk_empty;
      end
   endgenerate

endmodule // ni_be_endpoint
