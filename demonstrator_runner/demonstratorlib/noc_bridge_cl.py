"""
Copyright (c) 2019-2023 by the author(s)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=============================================================================

This class is the hostmod that directly interacts with the DI-NoC-Bridge debug
module on the device.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import osd
from demonstratorlib.constants import *
from math import ceil


REG_RD_TILE = 0x200
REG_RD_MAX_DI_PKT_LEN = 0x201
REG_RD_NOC_WIDTH = 0x202
REG_RD_NUM_LINKS = 0x203
REG_RD_NUM_EP_BE = 0x204
REG_RD_MAX_BE_PKT_LEN = 0x205
REG_RD_NUM_EP_TDM = 0x206
REG_RD_MAX_TDM_MSG_LEN = 0x207
REG_RD_ACT_BE = 0x208
REG_RD_ACT_TDM = 0x209
REG_RD_DR_ENABLED = 0x20a

REG_WR_ACT_BE = 0x208
REG_WR_ACT_TDM = 0x209

CTRL_MSG = 7

MOD = None
X_DIM = None
Y_DIM = None


class NoCBridgeClient(osd.Hostmod):
    def __init__(self, log, host_controller_address, event_handler=None, diaddr=None):
        global MOD
        MOD = self.__class__.__name__
        self.nb_diaddr = diaddr
        self.tile = None
        self.max_di_pkt_len = None
        self.noc_width = None
        self.num_links = None
        self.num_be_ep = None
        self.max_be_pkt_len = None
        self.num_tdm_ep = None
        self.max_tdm_msg_len = None
        self.dr_enabled = None
        self.connect()
        self._read_parameters()
        self.connect_debug_module()

    def connect_debug_module(self):
        # Set this hostmod as destination for event packets and activate module
        self.mod_set_event_dest(self.nb_diaddr)
        self.activate()

    def activate(self, ep="ALL"):
        self.mod_set_event_active(self.nb_diaddr)
        if ep == "ALL" or ep == "BE":
            self.activate_be()
        if ep == "ALL" or ep == "TDM":
            self.activate_tdm()

    def deactivate(self, ep="ALL"):
        self.mod_set_event_active(self.nb_diaddr, False)
        if ep == "ALL" or ep == "BE":
            self.activate_be(0)
        if ep == "ALL" or ep == "TDM":
            self.activate_tdm(0)

    def activate_be(self, activate=1):
        """
        Activate or deactivate BE endpoints.
        """
        self.reg_write(activate, self.nb_diaddr, REG_WR_ACT_BE)

    def check_be(self):
        return self.reg_read(self.nb_diaddr, REG_RD_ACT_BE)

    def activate_tdm(self, activate=1):
        """
        Activate or deactivate TDM endpoints.
        """
        self.reg_write(activate, self.nb_diaddr, REG_WR_ACT_TDM)

    def check_tdm(self):
        return self.reg_read(self.nb_diaddr, REG_RD_ACT_TDM)

    def _read_parameters(self):
        """
        Read all parameters from the module.
        """
        self.tile = self.reg_read(self.nb_diaddr, REG_RD_TILE)
        #print(self.tile)
        self.max_di_pkt_len = self.reg_read(self.nb_diaddr, REG_RD_MAX_DI_PKT_LEN)
        #print(self.max_di_pkt_len)
        self.noc_width = self.reg_read(self.nb_diaddr, REG_RD_NOC_WIDTH)
        #print(self.noc_width)
        self.num_links = self.reg_read(self.nb_diaddr, REG_RD_NUM_LINKS)
        #print(self.num_links)
        self.num_be_ep = self.reg_read(self.nb_diaddr, REG_RD_NUM_EP_BE)
        #print(self.num_be_ep)
        self.max_be_pkt_len = self.reg_read(self.nb_diaddr, REG_RD_MAX_BE_PKT_LEN)
        #print(self.max_be_pkt_len)
        self.num_tdm_ep = self.reg_read(self.nb_diaddr, REG_RD_NUM_EP_TDM)
        #print(self.num_tdm_ep)
        self.max_tdm_msg_len = self.reg_read(self.nb_diaddr, REG_RD_MAX_TDM_MSG_LEN)
        #print(self.max_tdm_msg_len)
        self.dr_enabled = True if self.reg_read(self.nb_diaddr, REG_RD_DR_ENABLED) == 1 else False
        #print(self.dr_enabled)

    def create_routing_table(self, x_dim, y_dim):
        self.routing_table = []
        for link in range(self.num_links):
            self.routing_table.append([])
            for dest in range(x_dim * y_dim):
                success, header = self.calculate_header_x_y(self.tile, dest, link, x_dim)
                if success:
                    self.routing_table[link].append(header)
                else:
                    self.routing_table[link].append(0)
                    print("{}: Too long path to tile {} from tile {}!".format(MOD, dest, self.tile))

    def calculate_header_x_y(self, source, dest, link, x_dim):
        """
        Calculate header flit for source routing to reach a defined destination
        from a defined source using X Y routing.
        """
        dest_x = dest % x_dim
        dest_y = dest // x_dim
        curr_x = source % x_dim
        curr_y = source // x_dim
        hop = 0
        header = 0

        # Route in x-dim
        while dest_x != curr_x:
            if dest_x < curr_x:
                nhop = 3
                curr_x -= 1
            else:
                nhop = 1
                curr_x += 1
            header |= (nhop & 0x7) << (hop * 3)
            hop += 1
        # Route in y-dim
        while dest_y != curr_y:
            if dest_y < curr_y:
                nhop = 0
                curr_y -= 1
            else:
                nhop = 2
                curr_y += 1
            header |= (nhop & 0x7) << (hop * 3)
            hop += 1
        header |= ((4 + link) & 0x7) << (hop * 3)
        success = True if ((hop * 3 ) < self.noc_width - 8) else False
        return success, header

    def _packetize(self, payload, width, maxlen):
        """
        Creates a list of packets to be sent via the DI. Each of these packets
        is a list of 16-bit values from the payload list with a given width. The
        number of 16-bit values is limited by 'maxlen' which defines the max.
        packet size in NoC width.
        These packets are later broken down in several DI packets, if necessary.
        The first value is the number of payload bytes to be sent.
        Currently, the number of bytes per payload is restricted to 2^16-1 bytes.
        In case of width == 8 or width == 16 the method first ensures that the
        payload are unsigned integers in a valid range (and otherwise sets the
        value to the highest possible).
        """
        # Check values
        if width == 8 or width == 16:
            maxval = 0xff if width == 8 else 0xffff
            for i in range(len(payload)):
                if payload[i] > maxval:
                    print("{}: Invalid value in payload word {}: {}. The value will be set to {}.".format(MOD, i, payload[i], maxval))
                    payload[i] = maxval
        # Determine number of payload bytes to be sent
        num_bytes = len(payload) * (width / 8)
        packed_payload = [[int(num_bytes)]]
        max_num_words = maxlen * (self.noc_width // 16)
        if width == 8:
            # Pack bytes together, fill last flit with zeros if necessary
            for i in range(int(len(payload)/2)):
                if len(packed_payload[-1]) == max_num_words:
                    packed_payload.append([])
                packed_payload[-1].append((payload[i*2+1] << 8) | payload[i*2])
            # Add last value in case of odd number of values
            if len(payload) % 2:
                if len(packed_payload[-1]) == max_num_words:
                    packed_payload.append([])
                packed_payload[-1].append(payload[-1])
        elif width == 16:
            # Directly write values to packed_payload but make sure to not
            # exceed max. DI packet length
            for i in range(int(len(payload))):
                if len(packed_payload[-1]) == max_num_words:
                    packed_payload.append([])
                packed_payload[-1].append(payload[i])
        else:
            # Fill first NoC flit with zero (lower 16 bits are number of bytes)
            packed_payload[-1].append(0)
            # Split values in 16-bit chunks
            for value in range(len(payload)):
                for word in range(width // 16):
                    if len(packed_payload[-1]) == max_num_words:
                        packed_payload.append([])
                    packed_payload[-1].append((payload[value] >> word * 16) & 0xffff)
        #print("{}: Packetized width: {}, payload: {}\npacked_payload: {}".format(MOD, width, [hex(h) for h in payload], [[hex(h) for h in list] for list in packed_payload]))
        return packed_payload

    def _create_event_pkt(self, type_sub, ep=None, header=None):
        """
        Create an event packet and initialize the header sections.
        """
        event_pkt = osd.Packet()
        event_pkt.set_header(src=self.diaddr, dest=self.nb_diaddr, type=2, type_sub=type_sub)
        if ep is not None:
            event_pkt.payload.append(ep)
        if header is not None:
            event_pkt.payload.append(header & 0xffff)
            event_pkt.payload.append((header >> 16) & 0xffff)
        return event_pkt

    def tile_ready(self, tile, endpoint):
        """
        Send a control message to a remote BE endpoint to check if it is enabled.
        """
        # Assemble header flit
        if self.dr_enabled:
            if endpoint > 1:
                print("{}: ep cannot be greater than 1. Currently: {}".format(MOD, endpoint))
                return
            header = CTRL_MSG << 29 | (endpoint & 0x1) << 23 | (self.tile & 0x3ff) << 10 | (tile & 0x3ff)
        else:
            header = CTRL_MSG << 29 | self.routing_table[endpoint][tile]
        event_pkt = self._create_event_pkt(0, endpoint, header)
        #print("{}: Checking if remote endpoint is ready. Tile {}, endpoint {}".format(MOD, tile, endpoint))
        self.event_send(event_pkt)

    def send_data_be(self, endpoint, dest, pkt_class, specific, payload, width=32):
        """
        Send data as BE packets.
        The payload will be split into several NoC packets if necessary.

        Current format:
            3 flits header, (1 flit endpoint descriptor), (2+ flits NoC header), (1+ flit payload length in bytes), 1-9 flits payload
        """
        # Ensure 'width' is a multiple of 8
        if width % 8 != 0:
            print("{}: Width of to be sent data must be a multiple of 8. Defined with: {}".format(MOD, width))
            return
        # Ensure that max. DI pkt length is sufficient for EP descriptor and NoC header
        min_di_pkt_len = 3 + 1 + self.noc_width // 16
        if self.max_di_pkt_len < min_di_pkt_len:
            print("{}: MAX_DI_PKT_LEN too small for BE header!".format(MOD, self.max_di_pkt_len))
            return
        # Create endpoint descriptor
        ep = endpoint & 0x7fff
        # Assemble header flit
        if self.dr_enabled:
            if ep > 1:
                print("{}: ep cannot be greater than 1. Currently: {}".format(MOD, ep))
                return
            header = (pkt_class & 0x7) << 29 | (specific & 0x1f) << 24 | (ep & 0x1) << 23 | (self.tile & 0x3ff) << 10 | (dest & 0x3ff)
        else:
            header = (pkt_class & 0x7) << 29 | (specific & 0x1f) << 24 | self.routing_table[ep][dest]
        #print("{}: Message to tile {} link {}: {}".format(MOD, dest, ep, bin(header)))
        # Create list of packets with 16-bit values for the payload
        packed_payload = self._packetize(payload, width, self.max_be_pkt_len - 1) # -1 since one flit is required for the header
        # Send event packets until all payload is sent
        first_pkt_payload = self.max_di_pkt_len - min_di_pkt_len
        for noc_pkt in range(len(packed_payload)):
            word = 0
            num_di_pkt = 1 if len(packed_payload[noc_pkt]) <= first_pkt_payload else 1 + ceil((len(packed_payload[noc_pkt]) - first_pkt_payload) / 9)
            for di_pkt in range(num_di_pkt):
                type_sub = 0 if di_pkt == num_di_pkt - 1 else 1
                # Only the first packet determines the EP & NoC header
                event_pkt = self._create_event_pkt(type_sub, ep, header) if di_pkt == 0 else self._create_event_pkt(type_sub)
                while len(event_pkt.payload) < self.max_di_pkt_len - 3:
                    event_pkt.payload.append(packed_payload[noc_pkt][word])
                    word += 1
                    if word == len(packed_payload[noc_pkt]):
                        break
                self.event_send(event_pkt)

    def send_data_tdm(self, endpoint, payload, width=32):
        """
        Send data as TDM message.
        The payload will be split into several NoC messages if necessary.

        Current format:
            3 flits header, (1 flit endpoint descriptor), (1+ flit payload length in bytes), 1-9 flits payload
        """
        # Ensure 'width' is a multiple of 8
        if width % 8 != 0:
            print("{}: Width of to be sent data must be a multiple of 8. Defined with: {}".format(MOD, width))
            return
        # Create endpoint descriptor
        ep = 1 << 15 | endpoint & 0x7fff
        #print("{}: TDM message to EP {}: {}".format(MOD, endpoint, [hex(h) for h in payload]))
        # Create list of packets with 16-bit values for the payload
        packed_payload = self._packetize(payload, width, self.max_tdm_msg_len)
        # Send event packets until all payload is sent
        for noc_pkt in range(len(packed_payload)):
            word = 0
            num_di_pkt = 1 if len(packed_payload[noc_pkt]) <= 8 else 1 + ceil((len(packed_payload[noc_pkt]) - 8) / 9)
            for di_pkt in range(num_di_pkt):
                type_sub = 0 if di_pkt == num_di_pkt - 1 else 1
                # Only the first packet determines the EP
                event_pkt = self._create_event_pkt(type_sub, ep) if di_pkt == 0 else self._create_event_pkt(type_sub)
                while len(event_pkt.payload) < self.max_di_pkt_len - 3:
                    event_pkt.payload.append(packed_payload[noc_pkt][word])
                    word += 1
                    if word == len(packed_payload[noc_pkt]):
                        break
                self.event_send(event_pkt)
