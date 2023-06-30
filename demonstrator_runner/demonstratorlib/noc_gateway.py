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

This class acts as a gateway to the device NoC. Multiple clients can sign up for
sending and receiving traffic of a certain class and endpoint.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import osd
from demonstratorlib.noc_bridge_cl import NoCBridgeClient, CTRL_MSG
from demonstratorlib.constants import *

import traceback
import sys

SRC = 'source'
CLASS = 'class'
EP = 'endpoint'
TYPE = 'type'
ID = 'cid'
BE = 0
TDM = 1

MOD = None


class NoCGateway:
    def __init__(self, log, host_controller_address, diaddr, x_dim, y_dim):
        global MOD
        MOD = self.__class__.__name__
        self.x_dim = x_dim
        # Create NoCBridgeClient for communication with target NoC
        self.noc_bridge = NoCBridgeClient(log, host_controller_address, event_handler=self.receive_handler, diaddr=diaddr)
        # In case of source routing, create routing table in NoCBridgeClient and
        # create and populate reverse routing table to identify senders by the
        # received source routed header.
        if not self.noc_bridge.dr_enabled:
            self.noc_bridge.create_routing_table(x_dim, y_dim)
        # Keep track of enabled BE endpoints
        self.remote_enabled = []
        for _ in range(self.noc_bridge.num_links):
            self.remote_enabled.append([])
            for _ in range(x_dim * y_dim):
                self.remote_enabled[-1].append(False)
        # Next client ID to be assigned
        self.nxt_cid = 0
        # Nested dictionary that determines which client receives which NoC
        # packets.
        self.cl_binds = {}
        # Dictionary with references to clients
        self.clients = {}

    def register_client(self, client):
        self.cl_binds[self.nxt_cid] = None
        self.clients[self.nxt_cid] = client
        self.nxt_cid += 1
        return self.nxt_cid - 1

    def unregister_client(self, cid):
        del self.cl_binds[cid]
        del self.clients[cid]

    def bind_traffic(self, cid, type=None, ep=None, pkt_class=None, src=None, width=32):
        if cid not in self.clients:
            print("{}: A client with CID {} is not registered!".format(MOD, cid))
        else:
            self.cl_binds[cid] = {}
            self.cl_binds[cid]['width'] = width
            if type is not None:
                self.cl_binds[cid][type] = {}
                if ep is not None:
                    self.cl_binds[cid][type][EP] = ep
                if pkt_class is not None:
                    self.cl_binds[cid][type][CLASS] = pkt_class
                if src is not None:
                    self.cl_binds[cid][type][SRC] = src

    def unbind_traffic(self, cid):
        self.cl_binds[cid] = None

    def tile_ready(self, tile, endpoint):
        """
        Check if a remote BE endpoint is marked as ready. If not, send a
        control message to check if it is enabled.
        Always returns 'False' the first time called for an endpoint.
        Note that no message is sent if the endpoint doesn't exist and 'False'
        will always be returned.
        """
        if self.remote_enabled[endpoint][tile] is False and endpoint < self.noc_bridge.num_be_ep:
            self.noc_bridge.tile_ready(tile, endpoint)
        return self.remote_enabled[endpoint][tile]

    def send_data_be(self, ep, dest, pkt_class, specific, payload, width=32):
        self.noc_bridge.send_data_be(ep, dest, pkt_class, specific, payload, width)

    def send_data_tdm(self, ep, payload, width=32):
        self.noc_bridge.send_data_tdm(ep, payload, width)

    def _unpack_payload(self, payload, type=BE, width=32):
        """
        Unpacks the payload from the received DI packet and structures it in the
        given word width. Returns a list with the values in the requested word
        width.
        For BE packets, the first word is always the 32-bit header.
        """
        # Ensure 'width' is a multiple of 8
        if width % 8 != 0:
            print("{}: Width of received data must be a multiple of 8. Defined with: {}".format(MOD, width))
            return []
        unpacked = []
        idx = 0
        if type == BE:
            header = payload[1] << 16 | payload[0]
            unpacked.append(header)
            idx = 2

        if width == 8:
            for i in range(idx, len(payload)):
                unpacked.append(payload[i] & 0xff)
                unpacked.append((payload[i] >> 8) & 0xff)
        elif width == 16:
            # Nothing to do, just extend unpacked
            unpacked.extend(payload[idx:])
        elif width == 32:
            if len(payload) % 2 != 0:
                print("{}: Invalid length for 32-bit receive: {} bytes\n{}".format(MOD, len(payload)*2, [hex(i) for i in payload]))
            for i in range(idx, len(payload), 2):
                unpacked.append(payload[i] | payload[i+1] << 16)
        else:
            print("{}: Unsupported width for receiving: {}".format(MOD, width))
        return unpacked

    def _find_source(self, sr_path):
        curr_tile = self.noc_bridge.tile
        ep = -1
        while ep < 0:
            nhop = sr_path & 0x7
            if nhop == 0:
                curr_tile -= self.x_dim
            elif nhop == 1:
                curr_tile += 1
            elif nhop == 2:
                curr_tile += self.x_dim
            elif nhop == 3:
                curr_tile -= 1
            elif nhop == 4:
                ep = 0
            elif nhop == 5:
                ep = 1
            else:
                print("{}: Invalid hop: '{}'!".format(MOD, nhop))
                return None
            sr_path >>= 3
        return curr_tile, ep

    def receive_handler(self, pkt):
        self.receive_event(pkt=pkt)
        return True

    def receive_event(self, blocking=False, pkt=None):
        """
        Receive events from the debug module (blocking) and distribute them to
        the registered clients (if any, otherwise discard).
        The first word of the payload determines the type (BE or TDM) and the
        endpoint the packet was received on.
        The remaining payload is the NoC packet (including header).
        Only the NoC packet will be forwarded to the clients.
        """
        try:
            if pkt is None:
                if blocking:
                    pkt = self.noc_bridge.event_receive(flags=1)
                else:
                    try:
                        pkt = self.noc_bridge.event_receive()
                    except osd.OsdErrorException as e:
                        if e.args[0] == -5:
                            pass
                        else:
                            print("{}: {}".format(MOD, e))
                        return
            if len(pkt.payload) < 3:
                print("{}: Received invalid event packet: {}".format(MOD, pkt))
                return
            if (len(pkt.payload) - 1) % 2 != 0:
                print("{}: Received event packet with invalid payload length: {}, payload: {}.".format(MOD, len(pkt.payload), [hex(h) for h in pkt.payload]))
                return
            type = (pkt.payload[0] >> 15) & 0x1
            ep = pkt.payload[0] & 0x7fff
            # Read payload into list object
            payload_lst = []
            for i in range(1, len(pkt.payload)):
                payload_lst.append(pkt.payload[i])
            #print("{}: Received type: {}, ep: {}, payload: {}".format(MOD, type, ep, [hex(h) for h in payload_lst]))
            if type == BE:
                header = pkt.payload[2] << 16 | pkt.payload[1]
                pkt_class = header >> 29
                if self.noc_bridge.dr_enabled:
                    src = (header >> 10) & 0x3ff
                else:
                    # Source routed packets can have different source and destination EPs.
                    # For DR packets it is assumed that the source EP is the same as the destination EP.
                    src, ep = self._find_source(header & 0xffffff)
                # Handle control packets
                if (pkt_class == CTRL_MSG):
                    #print("{}: Tile {} endpoints {} is enabled".format(MOD, src, ep))
                    self.remote_enabled[ep][src] = True
                else:
                    for cl in self.cl_binds:
                        if ((BE not in self.cl_binds[cl]) or
                            (EP not in self.cl_binds[cl][BE] or self.cl_binds[cl][BE][EP] == ep) and
                            (CLASS not in self.cl_binds[cl][BE] or self.cl_binds[cl][BE][CLASS] == pkt_class) and
                            (SRC not in self.cl_binds[cl][BE] or self.cl_binds[cl][BE][SRC] == src)):
                            unpacked = self._unpack_payload(payload_lst, type, self.cl_binds[cl]['width'])
                            self.clients[cl].receive(BE, ep, unpacked, src=src)
            elif type == TDM:
                for cl in self.cl_binds:
                    if ((TDM not in self.cl_binds[cl]) or
                        (EP not in self.cl_binds[cl][TDM] or self.cl_binds[cl][TDM][EP] == ep)):
                        unpacked = self._unpack_payload(payload_lst, type, self.cl_binds[cl]['width'])
                        self.clients[cl].receive(TDM, ep, unpacked)
            else:
                print("{}: Unknown traffic type: {}!".format(MOD, type))
        except Exception:
            print("{}: Error in receive handler!".format(MOD))
            print(traceback.format_exc())
