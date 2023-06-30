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

This class is the hostmod that configures the surveillance module and handles
the statistics data from the module.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import osd
from demonstratorlib.constants import *

# Debug module special registers
REG_RD_NUM_TDM_EP   = 0x200

# Memory mapped registers for remote core
REG_MAX_CLK_CNT     = 0x200
REG_XY_DIM          = 0x300
REG_MIN_BURST       = 0x304
REG_MAX_BURST       = 0x308
REG_MIN_DELAY       = 0x30c
REG_MAX_DELAY       = 0x310
REG_SEED            = 0x314
# Base register for the destination tile list
REG_DTL_BASE        = 0x400

# Clock counter for updates from surveillance module.
# The counter is set so that updates are sent twice per second at a frequency
# of 50MHz for the I/O tile, 50MHz for LCTs and 75MHz for HCTs.
MAX_CLOCK_VAL = {"I/O": 25000000, "LCT": 25000000, "HCT": 37500000}
#MAX_CLOCK_VAL = {"I/O": 10000, "LCT": 10000, "HCT": 10000} # alternative values for simulations

MOD = None


class SurveillanceModClient(osd.Hostmod):
    def __init__(self, log, host_controller_address, diaddr_surveillance_mods, x_dim, y_dim):
        global MOD
        MOD = self.__class__.__name__
        self.hm = osd.Hostmod(log, host_controller_address, event_handler=self.receive_handler)
        self.module_diaddrs = diaddr_surveillance_mods
        self.x_dim = x_dim
        self.y_dim = y_dim
        self.num_tdm_ep = []
        self.num_words = []
        self.stat_handler = None
        num_tiles = len(diaddr_surveillance_mods)
        self._initialize_buffer()

        self.hm.connect()

        # Number  of 16-bit words expected from each surveillance module
        # The module sends send/receive stats for each TDM EP and tile, all of
        # which are 32-bit values.
        for m in range(len(diaddr_surveillance_mods)):
            num_tdm_ep = self.hm.reg_read(self.module_diaddrs[m], REG_RD_NUM_TDM_EP)
            self.num_tdm_ep.append(num_tdm_ep)
            self.num_words.append(int((num_tdm_ep * 2 + num_tiles * 2 + 1) * 2))

        for diaddr in self.module_diaddrs:
            self.hm.mod_set_event_dest(diaddr)

    def _initialize_buffer(self):
        # Create a receive buffer for each surveillance module
        self.surveillance_enabled = False
        self.stats_buffer = []
        for _ in range(len(self.module_diaddrs)):
            self.stats_buffer.append([])

    def activate_surveillance(self):
        self.surveillance_enabled = True
        topology = "{}x{}".format(self.x_dim, self.x_dim)
        for tile in range(len(MAPPING[topology])):
            max_clk = MAX_CLOCK_VAL[MAPPING[topology][tile]]
            self._send_event_packet_for_reg_write(tile, REG_MAX_CLK_CNT, max_clk)

    def deactivate_surveillance(self):
        for tile in range(len(self.module_diaddrs)):
            self._send_event_packet_for_reg_write(tile, REG_MAX_CLK_CNT, 0)
        self._initialize_buffer()

    def get_num_tdm_ep(self, tile):
        return self.num_tdm_ep[tile]

    def _send_event_packet_for_reg_write(self, tile, reg_addr, data):
        event_pkt = osd.Packet()
        event_pkt.set_header(src=self.hm.diaddr, dest=self.module_diaddrs[tile], type=2, type_sub=0)
        event_pkt.payload.append(reg_addr)
        event_pkt.payload.append(data & 0xffff)
        event_pkt.payload.append((data >> 16) & 0xffff)
        self.hm.event_send(event_pkt)

    def set_clk_counter(self, tile, cnt):
        #print("{}: Tile {}, max. clk cnt {}".format(MOD, tile, cnt))
        self._send_event_packet_for_reg_write(tile, REG_MAX_CLK_CNT, cnt)

    def set_dimensions(self, tile, x, y):
        #print("{}: Tile {}, x-Dim {}, y-DIM {}".format(MOD, tile, x, y))
        data = ((x & 0xffff) << 16 | (y & 0xffff))
        self._send_event_packet_for_reg_write(tile, REG_XY_DIM, data)

    def set_min_burst(self, tile, min_burst):
        #print("{}: Tile {}, min_burst {}".format(MOD, tile, min_burst))
        self._send_event_packet_for_reg_write(tile, REG_MIN_BURST, min_burst)

    def set_max_burst(self, tile, max_burst):
        #print("{}: Tile {}, max_burst {}".format(MOD, tile, max_burst))
        self._send_event_packet_for_reg_write(tile, REG_MAX_BURST, max_burst)

    def set_min_delay(self, tile, min_delay):
        #print("{}: Tile {}, min_delay {}".format(MOD, tile, min_delay))
        self._send_event_packet_for_reg_write(tile, REG_MIN_DELAY, min_delay)

    def set_max_delay(self, tile, max_delay):
        #print("{}: Tile {}, max_delay {}".format(MOD, tile, max_delay))
        event_pkt = self._send_event_packet_for_reg_write(tile, REG_MAX_DELAY, max_delay)

    def set_seed(self, tile, seed):
        #print("{}: tile: {}, seed: {}".format(MOD, tile, seed))
        self._send_event_packet_for_reg_write(tile, REG_SEED, seed)

    def set_dest_list(self, tile, destinations):
        """
        The surveillance module has one register for every 32 tiles in the
        system. Each set bit defines an active target tile.
        """
        dtl = 0
        offset = 0
        for dest in range(len(destinations)):
            # Check if current destination tile is in a new register
            curroffset = dest // 32
            if curroffset > offset:
                # Send out current dtl
                self._send_event_packet_for_reg_write(tile, REG_DTL_BASE + (offset * 4), dtl)
                dtl = 0
                offset = curroffset
            if destinations[dest]['checked']:
                dtl |= 1 << dest
        # Write last dtl
        #print("{}: Tile {}, offset {}, dtl {}".format(MOD, tile, offset, dtl))
        self._send_event_packet_for_reg_write(tile, REG_DTL_BASE + (offset * 4), dtl)

    def set_stat_handler(self, stat_handler):
        self.stat_handler = stat_handler

    def _process_stats(self, tile):
        node_update = {'node': tile, 'tdm_sent': [], 'tdm_rcvd': [], 'be_sent': [], 'be_rcvd': [], 'be_faults': 0}
        stats = ['tdm_sent', 'tdm_rcvd', 'be_sent', 'be_rcvd', 'be_faults']
        num_values = [self.num_tdm_ep[tile], self.num_tdm_ep[tile], len(self.module_diaddrs), len(self.module_diaddrs), 1]
        for s in range(len(stats)):
            stat = stats[s]
            max_val = num_values[s]
            for val in range(max_val):
                low_word = self.stats_buffer[tile].pop(0)
                high_word = self.stats_buffer[tile].pop(0)
                if stat == 'be_faults':
                    node_update[stat] = high_word << 16 | low_word
                else:
                    node_update[stat].append(high_word << 16 | low_word)
        if self.stat_handler is not None:
            self.stat_handler(node_update)

    def _add_stats(self, tile, rcv_data):
        self.stats_buffer[tile].extend(rcv_data)
        if len(self.stats_buffer[tile]) == self.num_words[tile]:
            self._process_stats(tile)
        elif len(self.stats_buffer[tile]) > self.num_words[tile]:
            print("{}: Received too much data from tile {}. Expected {} words, received {}. Last packet: {}\nFull data: {}".format(MOD, tile, self.num_words[tile], len(self.stats_buffer[tile]), rcv_data, self.stats_buffer[tile]))
            self.stats_buffer[tile] = []

    def receive_handler(self, pkt):
        self.receive_event(pkt=pkt)
        return True

    def receive_event(self, blocking=False, pkt=None):
        """
        Receive packets from the NCM and forward them to the clients handling
        the packets, if any are registered.
        """
        if pkt is None:
            if blocking:
                pkt = self.hm.event_receive(flags=1)
            else:
                try:
                    pkt = self.hm.event_receive()
                except osd.OsdErrorException as e:
                    if e.args[0] == -5:
                        pass
                    else:
                        print("{}: {}".format(MOD, e))
                    return
        if self.surveillance_enabled:
            try:
                tile = self.module_diaddrs.index(pkt.src)
                # Read payload into list object
                payload_lst = []
                for i in range(len(pkt.payload)):
                    payload_lst.append(pkt.payload[i])
                self._add_stats(tile, payload_lst)
            except ValueError:
                print("{}: unknown debug module: {}".format(MOD, pkt.src))
            except Exeption:
                print("{}: something went wrong when receiving/processing stats!".format(MOD))
