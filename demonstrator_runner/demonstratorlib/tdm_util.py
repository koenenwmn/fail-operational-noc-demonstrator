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

Util classes to organize TDM paths, channels, and connections.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

from demonstratorlib.constants import *
from demonstratorlib.path_util import *


class TDMPath():
    """
    Helper class to handle a single TDM path.
    Two disjoint paths make up a channel.
    """
    def __init__(self, path, slots, link, ep_src, ep_dest):
        self.path = path
        self.slots = slots
        self.link = link
        self.ep_src = ep_src
        self.ep_dest = ep_dest
        self.channel = None
        self.path_idx = None

    def assign_channel(self, chid, path_idx):
        self.channel = chid
        self.path_idx = path_idx

    def valid_alternative_path(self, tdm_path):
        """
        Check if a given path is a valid alternative path to self.
        A path is a valid alternative path if it has the same start and end
        node, no shared links with self, uses another local link at source and
        destination, has the same amount of slots reserved, and uses the same
        endpoint on sender and receiver side.
        The path itself (sequence of nodes) is not checked for validity.
        """
        # Basic checks
        if (len(self.slots) != len(tdm_path.slots) or
            self.link == tdm_path.link or
            self.ep_src != tdm_path.ep_src or
            self.ep_dest != tdm_path.ep_dest or
            self.path[0] != tdm_path.path[0] or
            self.path[-1] != tdm_path.path[-1]):
            return False
        for hop_self in range(len(self.path)-1):
            for hop_other in range(len(tdm_path.path)-1):
                if (self.path[hop_self] == tdm_path.path[hop_other] and
                    self.path[hop_self+1] == tdm_path.path[hop_other+1]):
                    return False
        return True


class TDMChannel():
    """
    Helper class to handle a TDM channel between a source and destination that
    uses 1+1 protection.
    A channel has two disjoint paths.
    Two channels in opposite direction make up a connection
    """
    def __init__(self, src, dest, ep_src, ep_dest, numslots):
        self.paths = [None, None]
        self.pids = [None, None]
        self.errors = [False, False]
        self.src = src
        self.dest = dest
        self.ep_src = ep_src
        self.ep_dest = ep_dest
        self.numslots = numslots

    def set_error(self, path):
        if path < 2:
            self.errors[path] = True

    def clear_error(self, path):
        if path < 2:
            self.errors[path] = False

    def _check_valid_path_parameters(self, path):
        """
        Check if source, destination, endpoints, and number of slots match the
        channel parameters.
        """
        if (path.path[0] != self.src or
            path.path[-1] != self.dest or
            path.ep_src != self.ep_src or
            path.ep_dest != self.ep_dest or
            len(path.slots) != self.numslots):
            return False
        return True

    def add_path(self, path, pid):
        path_idx = -1
        if self._check_valid_path_parameters(path):
            if self.paths[0] == None:
                path_idx = 0
            elif self.paths[1] == None:
                path_idx = 1
            if path_idx >= 0:
                self.paths[path_idx] = path
                self.pids[path_idx] = pid
                self.errors[path_idx] = None
        # Return index of the added path or -1 if it could not be added
        return path_idx

    def clear_path(self, path_idx):
        pid = self.pids[path_idx]
        self.paths[path_idx] = None
        self.pids[path_idx] = None
        self.errors[path_idx] = None
        return pid

    def get_free_path_idx(self):
        if self.paths[0] is None:
            return 0
        elif self.paths[1] is None:
            return 1
        return -1

    def valid_return_channel(self, tdm_channel):
        if (tdm_channel.src != self.dest or
            tdm_channel.dest != self.src or
            tdm_channel.ep_src != self.ep_dest or
            tdm_channel.ep_dest != self.ep_src):
            return False
        return True


class TDMinfo():
    """
    Keeps track of all TDM channels including EPs in the nodes.
    Keeps track of reserved slots on the links and the channels/paths that use
    them.
    """
    def __init__(self, x_dim, y_dim, num_ep, slot_table_size):
        self.x_dim = x_dim
        self.y_dim = y_dim
        self.num_ep = num_ep
        self.slot_table_size = slot_table_size

        self._initialize_variables()

    def _initialize_variables(self):
        # Initialize nodes
        # Each node holds a list of its EPs and a reference to the channel ID
        # that uses the EP in in and out direction
        self.nodes = []
        for n in range(self.x_dim * self.y_dim):
            self.nodes.append([])
            for _ in range(self.num_ep[n]):
                self.nodes[-1].append([None, None])

        # Initialize LUT copy
        # Each slot contains the configured value and the path ID of the path
        # the slot is assigned to.
        self.table_config = []
        for n in range(self.x_dim * self.y_dim):
            # Index '0' for router and '1' for NIs
            self.table_config.append([[], []])
            # 6 output ports for routers
            for i in range(6):
                self.table_config[n][0].append([])
                for _ in range(self.slot_table_size):
                    self.table_config[n][0][i].append((EMPTY, None))
                # Only 4 slot tables for NIs (in and out for each link)
                if i < 4:
                    self.table_config[n][1].append([])
                    for _ in range(self.slot_table_size):
                        self.table_config[n][1][i].append((EMPTY, None))

    def reset(self):
        for n in range(self.x_dim * self.y_dim):
            for ep in range(self.num_ep[n]):
                self.nodes[n][ep] = [None, None]
        for n in range(self.x_dim * self.y_dim):
            for i in range(6):
                for s in range(self.slot_table_size):
                    self.table_config[n][0][i][s] = (EMPTY, None)
                if i < 4:
                    for s in range(self.slot_table_size):
                        self.table_config[n][1][i][s] = (EMPTY, None)

    def set_table_entry(self, node, ni, port, slot, config, pid):
        self.table_config[node][1 if ni else 0][port][slot] = (config, pid)

    def get_free_ep(self, node, out=True):
        """
        Checks if an EP is free (in 'out' or 'in' direction) and returns the
        first EP that is free, or -1 is none is free.
        """
        epdir = 0 if out else 1
        for ep in range(len(self.nodes[node])):
            if self.nodes[node][ep][epdir] is None:
                return ep
        return -1

    def assign_ep(self, src, dest, ep_src, ep_dest, chid):
        if (self.nodes[src][ep_src][0] is None and
            self.nodes[dest][ep_dest][1] is None):
            self.nodes[src][ep_src][0] = chid
            self.nodes[dest][ep_dest][1] = chid
            return True
        return False

    def check_path(self, path, start_slot, link, ep_src, ep_dest):
        """
        Check if a given path is free.
        """
        hop = 0
        free = True if self.table_config[path[0]][1][link][start_slot][0] is EMPTY else False
        # Do sanity checks
        if (not check_valid_path(self.x_dim, path) or
            ep_src >= self.num_ep[path[0]] or
            ep_dest >= self.num_ep[path[-1]] or
            link > 1 or
            start_slot >= self.slot_table_size):
            free = False
        slot = start_slot
        # Check slots in slot tables along the path
        while hop < len(path) and free:
            if hop < len(path) - 1:
                c_node = path[hop]
                n_node = path[hop+1]
                out_port = 0 if c_node - self.x_dim == n_node else 1 if c_node + 1 == n_node else 2 if c_node + self.x_dim == n_node else 3
            else:
                out_port = link + 4
            if self.table_config[path[hop]][0][out_port][slot][0] is not EMPTY:
                free = False
            slot = (slot + 1) % self.slot_table_size
            hop += 1
        if self.table_config[path[-1]][1][link+2][slot][0] is not EMPTY:
            free = False
        return free

    def get_free_slots(self, path, ep_src, ep_dest, link, numslots):
        start_slots = []
        # Find start slots with a free path
        for slot in range(self.slot_table_size):
            slot_available = self.check_path(path, slot, link, ep_src, ep_dest)
            if slot_available:
                start_slots.append(slot)
            if len(start_slots) == numslots:
                return start_slots
        return []
