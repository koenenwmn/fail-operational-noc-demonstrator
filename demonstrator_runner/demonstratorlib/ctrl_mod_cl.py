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

This class is the hostmod that directly interacts with the NoC control module on
the device.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import osd
from demonstratorlib.constants import *
from demonstratorlib.tdm_util import *
from demonstratorlib.path_util import *


REG_RD_SLOT_TABLE_SIZE = 0x200
REG_RD_DIMENSIONS = 0x201
REG_RD_UPDATE_PERIOD_LOW = 0x202
REG_RD_UPDATE_PERIOD_HIGH = 0x203
REG_RD_MAX_PORTS = 0x204
REG_RD_SIMPLE_NCM = 0x205
SUB_ID_FD = 0
SUB_ID_UTIL = 1

FAULT_CONFIG = 0
TDM_CONFIG = 1
CLK_CONFIG = 2

MOD = None


class CtrlModClient(osd.Hostmod):
    def __init__(self, log, host_controller_address, diaddr_ctrl_mod):
        global MOD
        MOD = self.__class__.__name__
        self.hm = osd.Hostmod(log, host_controller_address, event_handler=self.receive_handler)
        self.module_diaddr = diaddr_ctrl_mod
        self._util_handler = None
        self._fd_handler = None

        # set_num_tdm_ep() must be called before starting to configure the NoC
        self.num_tdm_ep = None
        self.tdm_info = None

        self.hm.connect()
        self._initialize_variables()
        self.hm.mod_set_event_dest(self.module_diaddr)

    def _initialize_variables(self):
        self.slot_table_size = self.hm.reg_read(self.module_diaddr, REG_RD_SLOT_TABLE_SIZE)
        dimensions = self.hm.reg_read(self.module_diaddr, REG_RD_DIMENSIONS)
        self.x_dim = dimensions & 0xff
        self.y_dim = (dimensions >> 8) & 0xff
        self.max_num_tdm_ep = self.hm.reg_read(self.module_diaddr, REG_RD_MAX_PORTS)
        self.simple_ncm = self.hm.reg_read(self.module_diaddr, REG_RD_SIMPLE_NCM)
        self.fault_vector = [0] * (self.x_dim * self.y_dim)
        # Dictionary keeping track of all configured TDM channels. pid is key
        self.nxt_pid = 0
        self.tdm_channels = {}
        # Dictionary keeping track of all configured TDM paths. chid is key
        self.nxt_chid = 0
        self.tdm_paths = {}

    def _reset_variables(self):
        self.fault_vector = [0] * (self.x_dim * self.y_dim)
        self.nxt_pid = 0
        self.tdm_channels = {}
        self.nxt_chid = 0
        self.tdm_paths = {}
        if self.tdm_info is not None:
            self.tdm_info.reset()

    def _reset_faults(self):
        for node in range(self.x_dim * self.y_dim):
            event_pkt = self._create_event_pkt(FAULT_CONFIG)
            event_pkt.payload.append((node << 8))
            self.hm.event_send(event_pkt)

    def set_num_tdm_ep(self, num_tdm_ep):
        """
        The module can only read the max. number of EPs in the system but not
        the actual number that each node has. This must be set post
        initialization (in form of a list).
        """
        self.num_tdm_ep = num_tdm_ep
        # Create object to mirror status of slots tables and EPs
        self.tdm_info = TDMinfo(self.x_dim, self.y_dim, num_tdm_ep, self.slot_table_size)

    def reset(self):
        self._reset_variables()
        self._reset_faults()

    def activate_monitoring(self, max_clk_cnt):
        self._configure_util_clk_cnt(max_clk_cnt)
        self.hm.mod_set_event_active(self.module_diaddr)

    def deactivate_monitoring(self):
        self._configure_util_clk_cnt(0)
        try:
            self.hm.mod_set_event_active(self.module_diaddr, False)
        except osd.OsdErrorException as e:
            if e.args[0] == -5:
                pass
            else:
                print(e)

    def register_util_handler(self, handler):
        if self._util_handler is not None:
            return False
        self._util_handler = handler
        return True

    def unregister_util_handler(self, handler):
        if self._util_handler != handler:
            return False
        self._util_handler = None
        return True

    def register_fd_handler(self, handler):
        if self._fd_handler is not None:
            return False
        self._fd_handler = handler
        return True

    def unregister_fd_handler(self, handler):
        if self._fd_handler != handler:
            return False
        self._fd_handler = None
        return True

    def _create_event_pkt(self, sub_mod):
        """
        Create an event packet and initialize the header sections.
        """
        event_pkt = osd.Packet()
        event_pkt.set_header(src=self.hm.diaddr, dest=self.module_diaddr, type=2, type_sub=0)
        event_pkt.payload.append(sub_mod)
        return event_pkt

    def _configure_util_clk_cnt(self, max_clk_cnt):
        event_pkt = self._create_event_pkt(CLK_CONFIG)
        event_pkt.payload.append(max_clk_cnt & 0xffff)
        event_pkt.payload.append((max_clk_cnt >> 16) & 0xffff)
        self.hm.event_send(event_pkt)

    def _configure_slot_table(self, node, port, slot, config, pid=None, ni=False):
        """
        Configure a single entry of a slot table.
        Bits 0-14 of the first payload flit determine the node, the MSB
        determines whether a NI shall be configured (1) or a router (0).
        The low byte of the second payload flit determines the slot table (port)
        (bits 0-3) and the config (input port or endpoint that is to be
        forwarded)(bits 4-7). The high byte determines the slot in the table.
        For NIs, ports 0 and 1 are the outgoing ports, ports 2 and 3 are the
        incoming ports.
        Max. possible values:
         - nodes: 32,768
         - router ports and endpoints: 16
         - slot table size: 256
        """
        event_pkt = self._create_event_pkt(TDM_CONFIG)
        event_pkt.payload.append(((slot & 0xff) << 8) | ((config & 0xf) << 4) | (port & 0xf))
        msb = (1 << 15) if ni else 0
        event_pkt.payload.append(msb | (node & 0x7fff))
        self.hm.event_send(event_pkt)
        if self.tdm_info is not None:
            self.tdm_info.set_table_entry(node, ni, port, slot, config, pid)

    def _configure_ep_link(self, node, ep, link, enable=True):
        """
        Enable or disable a link for the out queue of a TDM endpoint.
        """
        event_pkt = self._create_event_pkt(TDM_CONFIG)
        event_pkt.payload.append(((link & 0xff) << 8) | ((1 if enable else 0) << 4) | (ep & 0xf))
        event_pkt.payload.append((1 << 14) | (node & 0x7fff))
        self.hm.event_send(event_pkt)

    def create_path_dict(self):
        """
        Creates a dictionary with all TDM paths in the NoC. The dictionary can
        be sent to the monitoring GUI.
        """
        paths = {}
        for p in self.tdm_paths:
            paths[p] = {'path_x': [n % self.x_dim for n in self.tdm_paths[p].path],
                        'path_y': [n // self.x_dim for n in self.tdm_paths[p].path],
                        'path': self.tdm_paths[p].path,
                        'ep_src': self.tdm_paths[p].ep_src,
                        'ep_dest': self.tdm_paths[p].ep_dest,
                        'chid': self.tdm_paths[p].channel,
                        'path_idx': self.tdm_paths[p].path_idx}
        return paths

    def create_channel_dict(self):
        """
        Creates a dictionary with all TDM channels in the NoC. The dictionary
        can be sent to the monitoring GUI.
        """
        channels = {}
        for c in self.tdm_channels:
            channels[c] = {'pids': self.tdm_channels[c].pids,
                           'errors': self.tdm_channels[c].errors,
                           'src_x': self.tdm_channels[c].src % self.x_dim,
                           'src_y': self.tdm_channels[c].src // self.x_dim,
                           'dest_x': self.tdm_channels[c].dest % self.x_dim,
                           'dest_y': self.tdm_channels[c].dest // self.x_dim,
                           'ep_src': self.tdm_channels[c].ep_src,
                           'ep_dest': self.tdm_channels[c].ep_dest}
        return channels

    def create_tdm_channel(self, src, dest, numslots=1, autopaths=True):
        """
        Creates a new TDM channel between two nodes.
        If 'autopaths' is set, two disjoint paths will be automatically created
        using x-y and y-x routing respectively.
        If 'autopaths' is not set then it simply creates the empty channel.
        Returns the channel id on success or '-1' if it fails.
        """
        # First, check for free EPs
        ep_src = self.tdm_info.get_free_ep(src, out=True)
        ep_dest = self.tdm_info.get_free_ep(dest, out=False)
        if ep_src == -1 or ep_dest == -1:
            return -1

        # Check if autopaths are possible
        if autopaths:
            path_A = find_path_A(self.x_dim, src, dest)
            path_B = find_path_B(self.x_dim, self.y_dim, src, dest)
            start_slots_A = self.tdm_info.get_free_slots(path_A, ep_src, ep_dest, 0, numslots)
            start_slots_B = self.tdm_info.get_free_slots(path_B, ep_src, ep_dest, 1, numslots)
            if len(start_slots_A) == 0 or len(start_slots_B) == 0:
                return -2
            pid_A = self._configure_tdm_path(path_A, start_slots_A, ep_src, ep_dest, 0)
            pid_B = self._configure_tdm_path(path_B, start_slots_B, ep_src, ep_dest, 1)

        chid = self.nxt_chid
        self.tdm_channels[chid] = TDMChannel(src, dest, ep_src, ep_dest, numslots)
        self.tdm_info.assign_ep(src, dest, ep_src, ep_dest, chid)
        self.nxt_chid += 1

        # Add autopaths to channel and vice versa
        if autopaths:
            path_idx = self.tdm_channels[chid].add_path(self.tdm_paths[pid_A], pid_A)
            self.tdm_paths[pid_A].assign_channel(chid, path_idx)
            path_idx = self.tdm_channels[chid].add_path(self.tdm_paths[pid_B], pid_B)
            self.tdm_paths[pid_B].assign_channel(chid, path_idx)

        return chid

    def delete_tdm_channel(self, chid):
        """
        Clears all TDM paths associated with a channel and deletes the channel.
        """
        if chid in self.tdm_channels:
            for p in range(len(self.tdm_channels[chid].pids)):
                self._clear_tdm_path(self.tdm_channels[chid].pids[p])
            del self.tdm_channels[chid]

    def add_path_to_channel(self, chid, path_idx, path):
        retval = 2
        # Check if path_idx is free
        if self.tdm_channels[chid].paths[path_idx] is None:
            ep_src = self.tdm_channels[chid].ep_src
            ep_dest = self.tdm_channels[chid].ep_dest
            # Check if path is valid
            start_slots = self.tdm_info.get_free_slots(path, ep_src, ep_dest,
                                                       path_idx, self.tdm_channels[chid].numslots)
            if len(start_slots) > 0:
                pid = self._configure_tdm_path(path, start_slots, ep_src, ep_dest, path_idx)
                # Check if other path, if configured, is disjoint
                disjoint = True
                pid_alt = self.tdm_channels[chid].pids[(path_idx+1)%2]
                if pid_alt is not None:
                    disjoint = self.tdm_paths[pid_alt].valid_alternative_path(self.tdm_paths[pid])
                if not disjoint or self.tdm_channels[chid].add_path(self.tdm_paths[pid], pid) < 0:
                    self._clear_tdm_path(pid)
                    if not disjoint:
                        retval = 1
                else:
                    retval = 0
        return retval

    def remove_path_from_channel(self, chid, path_idx):
        pid = self.tdm_channels[chid].clear_path(path_idx)
        self._clear_tdm_path(pid)

    def _configure_tdm_path(self, path, start_slots, ep_src, ep_dest, link):
        # Add a new TDM path to the list
        pid = self.nxt_pid
        self.tdm_paths[pid] = TDMPath(path, start_slots, link, ep_src, ep_dest)
        self.nxt_pid += 1
        # Configure path
        for slot in start_slots:
            self._configure_slot_table(self.tdm_paths[pid].path[0], link, slot, ep_src, pid, True)
            currslot = slot
            hop = 0
            in_port = link + 4
            while hop < len(path):
                if hop < len(path) - 1:
                    c_node = path[hop]
                    n_node = path[hop+1]
                    out_port = 0 if c_node - self.x_dim == n_node else 1 if c_node + 1 == n_node else 2 if c_node + self.x_dim == n_node else 3
                else:
                    out_port = link + 4
                self._configure_slot_table(path[hop], out_port, currslot, in_port, pid)
                currslot = (currslot + 1) % self.slot_table_size
                hop += 1
                in_port = 0 if out_port == 2 else 1 if out_port == 3 else 2 if out_port == 0 else 3
            self._configure_slot_table(path[-1], link + 2, currslot, ep_dest, pid, True)
        # Enable link
        self._configure_ep_link(path[0], ep_src, link)
        return pid

    def configure_tdm_path_raw(self, path, slots, ep_src, ep_dest, link):
        """
        Configure a TDM path in the system with given slots.
        No checking is done and existing paths are overwritten!
        The paths are also not given ID.
        """
        #print("{}: Configure path {}, slots {}, ep_src {}, ep_dest {}, link {}".format(MOD, path, slots, ep_src, ep_dest, link))
        for slot in slots:
            self._configure_slot_table(path[0], link, slot, ep_src, ni=True)
            currslot = slot
            hop = 0
            in_port = link + 4
            while hop < len(path):
                if hop < len(path) - 1:
                    c_node = path[hop]
                    n_node = path[hop+1]
                    out_port = 0 if c_node - self.x_dim == n_node else 1 if c_node + 1 == n_node else 2 if c_node + self.x_dim == n_node else 3
                else:
                    out_port = link + 4
                self._configure_slot_table(path[hop], out_port, currslot, in_port)
                currslot = (currslot + 1) % self.slot_table_size
                hop += 1
                in_port = 0 if out_port == 2 else 1 if out_port == 3 else 2 if out_port == 0 else 3
            self._configure_slot_table(path[-1], link + 2, currslot, ep_dest, ni=True)
        # Enable link
        self._configure_ep_link(path[0], ep_src, link)

    def _clear_tdm_path(self, pid):
        if pid not in self.tdm_paths:
            return False
        # Read parameters from TDM path
        path = self.tdm_paths[pid].path
        start_slots = self.tdm_paths[pid].slots
        link = self.tdm_paths[pid].link
        ep_src = self.tdm_paths[pid].ep_src
        ep_dest = self.tdm_paths[pid].ep_dest
        # Deactivate link
        self._configure_ep_link(path[0], ep_src, link, False)
        # Clear path
        for slot in start_slots:
            self._configure_slot_table(path[0], link, slot, EMPTY, None, True)
            currslot = slot
            hop = 0
            in_port = link + 4
            while hop < len(path):
                if hop < len(path) - 1:
                    c_node = path[hop]
                    n_node = path[hop+1]
                    out_port = 0 if c_node - self.x_dim == n_node else 1 if c_node + 1 == n_node else 2 if c_node + self.x_dim == n_node else 3
                else:
                    out_port = link + 4
                self._configure_slot_table(path[hop], out_port, currslot, EMPTY, None)
                currslot = (currslot + 1) % self.slot_table_size
                hop += 1
                in_port = 0 if out_port == 2 else 1 if out_port == 3 else 2 if out_port == 0 else 3
            self._configure_slot_table(path[-1], link + 2, currslot, EMPTY, None, True)
        # Delete TDM path entry
        del self.tdm_paths[pid]
        return True

    def configure_faults(self, node, link, set_fault=True):
        """
        Sets or clears a fault on a specified link.
        """
        if set_fault:
            self.fault_vector[node] |= 0x1 << link
        else:
            self.fault_vector[node] = self.fault_vector[node] & ~(1 << link)
        event_pkt = self._create_event_pkt(FAULT_CONFIG)
        event_pkt.payload.append((node << 8) | (self.fault_vector[node] & 0xff))
        self.hm.event_send(event_pkt)

    def receive_handler(self, pkt):
        self.receive_event(pkt=pkt)
        return True

    def receive_event(self, blocking=False, pkt=None):
        """
        Receive packets from the NCM and forward them to the handler handling
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
        if len(pkt.payload) < 2:
            print("{}: Received invalid event packet ({} payload words).".format(MOD, pkt.size_payload_words))
            return
        # Handle packets from the NCM
        if pkt.src == self.module_diaddr:
            sub_id = pkt.payload[0] & 0b11
            # Read payload into list object
            payload_lst = list(pkt.payload)
            if sub_id == SUB_ID_FD:
                if self._fd_handler is not None:
                    self._fd_handler(payload_lst)
            elif sub_id == SUB_ID_UTIL:
                if self._util_handler is not None:
                    try:
                        self._util_handler(payload_lst)
                    except Exception:
                        print("{}: error when calling handler".format(MOD))
            else:
                print("{}: Invalid sub-id: {}.".format(MOD, pkt.payload[0]))
        else:
            print("{}: Invalid packet source '{}', expected '{}'.".format(MOD, pkt.src, self.module_diaddr))
