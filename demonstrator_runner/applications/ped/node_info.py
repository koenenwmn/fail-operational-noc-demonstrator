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

These classes hold information about the nodes.

Each info class defines the layout of the info area in the GUI.
They all have at least an 'info' tab and possibly additional tabs to organize
the interface.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

from demonstratorlib.constants import *
import random

LCT = "LCT"
HCT = "HCT"
IO = "I/O"

MOD = None
X_DIM = None
Y_DIM = None

class NodeInfo():
    def __init__(self, nodeid, x_dim, y_dim, num_tdm_ep):
        global MOD, X_DIM, Y_DIM
        MOD = self.__class__.__name__
        X_DIM = x_dim
        Y_DIM = y_dim
        self.topology = "{}x{}".format(X_DIM, Y_DIM)
        self.type = MAPPING[self.topology][nodeid]
        self.nodeid = nodeid    # Total ID of the node
        self.x = nodeid % X_DIM
        self.y = nodeid // X_DIM
        self.num_tdm_ep = num_tdm_ep
        self.typeid = 0         # ID of the node type (e.g. if nodeid is '1' then typeid can be '0' if it is the 0th node of this type)
        for n in range(self.nodeid):
            if MAPPING[self.topology][n] is self.type:
                self.typeid += 1
        self.infostr = ''
        self.reset_stats()

    def reset_stats(self):
        self.stats = {'tdm_sent': [], 'tdm_rcvd': [], 'be_sent': [], 'be_rcvd': [], 'be_faults': 0}
        for _ in range(self.num_tdm_ep):
            self.stats['tdm_sent'].append(0)
            self.stats['tdm_rcvd'].append(0)
        for _ in range(X_DIM * Y_DIM):
            self.stats['be_sent'].append(0)
            self.stats['be_rcvd'].append(0)

    def get_stats(self):
        return self.stats

    def get_num_tdm_ep(self):
        return self.num_tdm_ep

    def get_info_str(self):
        """
        Returns an info string to be displayed in monitor UI.
        This info string must be created by the derived classes.
        """
        return self.infostr

    def update_stats(self, stats):
        try:
            for ep in range(self.num_tdm_ep):
                self.stats['tdm_sent'][ep] += stats['tdm_sent'][ep]
                self.stats['tdm_rcvd'][ep] += stats['tdm_rcvd'][ep]
            for node in range(X_DIM * Y_DIM):
                self.stats['be_sent'][node] += stats['be_sent'][node]
                self.stats['be_rcvd'][node] += stats['be_rcvd'][node]
            self.stats['be_faults'] += stats['be_faults']
        except Exception:
            print("{}: Error while updating stats with: '{}'!".format(MOD, stats))

    def print_stats(self):
        for ep in range(self.num_tdm_ep):
            print("{}: Tile {} TDM ep {} sent: {}".format(MOD, self.nodeid, ep, self.stats['tdm_sent'][ep]))
            print("{}: Tile {} TDM ep {} received: {}".format(MOD, self.nodeid, ep, self.stats['tdm_rcvd'][ep]))
        for node in range(X_DIM * Y_DIM - 1):
            print("{}: Tile {} BE tile {} sent: {}".format(MOD, self.nodeid, ep, self.stats['be_sent'][ep]))
            print("{}: Tile {} BE tile {} received: {}".format(MOD, self.nodeid, ep, self.stats['be_rcvd'][ep]))
        print("{}: Tile {} BE faults: {}".format(MOD, self.nodeid, self.stats['be_faults']))


class NodeInfoIO(NodeInfo):
    def __init__(self, nodeid, x_dim, y_dim, num_tdm_ep):
        super().__init__(nodeid, x_dim, y_dim, num_tdm_ep)
        self._generate_info_str()

    def _generate_info_str(self):
        """
        Generate the info string for I/O node.
        """
        self.infostr += '<center><b>Tile {}</b> (I/O)</center>'.format(self.nodeid)
        # Create tabs for different sections (only info section for now)
        self.infostr += '<ul class="tabs">'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-0" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-0\', \'nodeTabContent-0\')">Info</button>'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-1" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-1\', \'nodeTabContent-1\')">Config TDM</button>'
        self.infostr += '</ul>'

        # Create info tab
        self.infostr += '<div id="nodeTabContent-0" class="nodetabcontent">'.format(self.nodeid)
        self.infostr += '<center>'
        self.infostr += '<table>'
        self.infostr += '<tr><th>TDM Endpoint</th><th style="width:90px;text-align:right">Sent</th><th style="width:90px;text-align:right">Received</th></tr>'
        for ep in range(self.num_tdm_ep):
            self.infostr += '<tr><td>EP {}:</td><td id="sent_ep_{}" style="text-align:right">sent</td><td id="rcvd_ep_{}" style="text-align:right">rec</td></tr>'.format(ep, ep, ep)
        self.infostr += '</table>'
        self.infostr += 'Faulty BE packets received: <span id="faulty_be">faulty</span>'
        self.infostr += '</div>'

        # TDM channel config box
        self.infostr += '<div id="nodeTabContent-1" class="nodetabcontent">'.format(self.nodeid)
        for ep in range(self.num_tdm_ep):
            self.infostr += '<table style="width:100%"><tr>'
            self.infostr += '<td width="30%">Channel to node <span id="channel_dest_{}">n/a</span></td>'.format(ep)
            self.infostr += '<td width="60%">Path 0: <span id="path_0_channel_{}">-</span></td>'.format(ep)
            self.infostr += '<td width="10%" align="right">'
            self.infostr += '<button id="btn_set_clr_ch_{}_path_0" type="submit" onclick="nocInfo.configureTDMpath({}, 0)"></button></td>'.format(ep, ep)
            self.infostr += '</tr><tr>'
            self.infostr += '<td width="30%"></td>'
            self.infostr += '<td width="60%">Path 1: <span id="path_1_channel_{}">-</span></td>'.format(ep)
            self.infostr += '<td width="10%" align="right">'
            self.infostr += '<button id="btn_set_clr_ch_{}_path_1" type="submit" onclick="nocInfo.configureTDMpath({}, 1)"></button></td>'.format(ep, ep)
            self.infostr += '</tr></table>'
            if ep < self.num_tdm_ep - 1:
                self.infostr += '<hr noshade size=1>'
        self.infostr += '</div>'

    def reset(self):
        super().reset_stats()

    def update_stats(self, stats):
        super().update_stats(stats)


class NodeInfoLCT(NodeInfo):
    def __init__(self, nodeid, x_dim, y_dim, num_tdm_ep):
        super().__init__(nodeid, x_dim, y_dim, num_tdm_ep)
        self._init_lct_stats()
        self._generate_info_str()

    def _generate_info_str(self):
        """
        Generate the info string for LCT node.
        """
        self.infostr += '<center><b>Tile {}</b> (LC Core {})</center>'.format(self.nodeid, self.typeid)
        # Create tabs for different sections (only info section for now)
        self.infostr += '<ul class="tabs">'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-0" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-0\', \'nodeTabContent-0\')">Info</button>'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-1" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-1\', \'nodeTabContent-1\')">Config BE</button>'
        self.infostr += '</ul>'

        # Create info tab
        self.infostr += '<div id="nodeTabContent-0" class="nodetabcontent">'.format(self.nodeid)
        self.infostr += '<center>'
        self.infostr += '<table>'
        for tile in range(len(MAPPING[self.topology])):
            disabled = self.specific["lct_dest"][tile]["disabled"]
            disabledstr = ';color:#cccccc' if disabled else ''
            self.infostr += '<tr>' if tile % X_DIM == 0 else ''
            self.infostr += '<td id="sent_rec_node_{}" style="text-align:center;width:90px;height:40px{}">sent /<br/>received</td>'.format(tile, disabledstr)
            if (tile + 1) % X_DIM == 0:
                if tile < X_DIM:
                    self.infostr += '<td style="text-align:center;width:120px;height:40px;background:#cccccc;border:1px solid black">Sent /<br/>Received</td></tr>'
                else:
                    self.infostr += '</tr>' if (tile + 1) % X_DIM == 0 else ''
        self.infostr += '</table>'
        self.infostr += 'Faulty BE packets received: <span id="faulty_be">faulty</span>'
        self.infostr += '</div>'

        # TDM channel config box
        self.infostr += '<div id="nodeTabContent-1" class="nodetabcontent">'.format(self.nodeid)
        # Create checkboxes for destinations
        self.infostr += '<center>'
        self.infostr += '<table>'
        for dest in range(len(MAPPING[self.topology])):
            disabled = self.specific["lct_dest"][dest]["disabled"]
            self.infostr += '<tr>' if dest % X_DIM == 0 else ''
            self.infostr += '<td><input type="checkbox" id="swNode{}" onclick="nocInfo.toggleDestination({},{})"{}>'.format(dest, self.nodeid, dest, ' disabled="true"' if disabled else '')
            self.infostr += '<font color={}>Tile {}</font></td>'.format("#cccccc" if disabled else "#000000", dest)
            self.infostr += '</tr>' if (dest + 1) % X_DIM == 0 else ''
        self.infostr += '</table>'
        # Create input fields to set burst and delay between packets
        self.infostr += '<table style="width:100%"><tr>'
        self.infostr += '<td>Burst length: <span id="burstLen">burst</span> packets</td>'
        self.infostr += '<td><form class="input-right" action="javascript: nocInfo.setBurst({})">'.format(self.nodeid)
        self.infostr += '<input type="text" id="burstCommandLine"></input>'
        self.infostr += '<input id="btnSetBurst" type="submit" value="Set"></button>'
        self.infostr += '</form></td>'
        self.infostr += '</tr><tr>'
        self.infostr += '<td>Processing delay: <span id="loopIter">loops</span> loop iterations</td>'
        self.infostr += '<td><form class="input-right" action="javascript: nocInfo.setProcDelay({})">'.format(self.nodeid)
        self.infostr += '<input type="text" id="procDelayCommandLine"></input>'
        self.infostr += '<input id="btnSetProcDelay" type="submit" value="Set"></button>'
        self.infostr += '</form></td>'
        self.infostr += '</tr></table>'
        self.infostr += '</div>'

    def _init_lct_stats(self):
        self.specific = {}
        # Traffic pattern
        self.specific["min_burst"] = 0
        self.specific["max_burst"] = 50
        self.specific["min_delay"] = 50
        self.specific["max_delay"] = 500
        # List of destinations
        self.specific["lct_dest"] = []
        for dest in range(len(MAPPING[self.topology])):
            self.specific["lct_dest"].append({})
            # Only allow sending BE packets among LCTs but not to self
            self.specific["lct_dest"][-1]["disabled"] = False if MAPPING[self.topology][dest] == "LCT" and dest != self.nodeid else True
            # Enable sending to all other LCTs by default
            self.specific["lct_dest"][-1]["checked"] = True if MAPPING[self.topology][dest] == "LCT" and dest != self.nodeid else False

    def reset(self):
        super().reset_stats()
        self._init_lct_stats()

    def update_stats(self, stats):
        super().update_stats(stats)

    # Type specific methods
    def set_proc_delay(self, max, min=None):
        self.specific["max_delay"] = max
        self.specific["min_delay"] = min if min is not None else max

    def get_proc_delay(self):
        return self.specific["min_delay"], self.specific["max_delay"]

    def set_burst(self, max, min=None):
        self.specific["max_burst"] = max
        self.specific["min_burst"] = min if min is not None else max

    def get_burst(self):
        return self.specific["min_burst"], self.specific["max_burst"]

    def set_dest(self, dest, enabled):
        self.specific["lct_dest"][dest]["checked"] = enabled

    def get_dest_list(self):
        return self.specific["lct_dest"]

    def get_be_conf(self):
        return self.specific


class NodeInfoHCT(NodeInfo):
    def __init__(self, nodeid, x_dim, y_dim, num_tdm_ep):
        super().__init__(nodeid, x_dim, y_dim, num_tdm_ep)
        self._generate_info_str()

    def _generate_info_str(self):
        """
        Generate the info string for HCT node.
        """
        self.infostr += '<center><b>Tile {}</b> (HC Core {})</center>'.format(self.nodeid, self.typeid)
        # Create tabs for different sections (only info section for now)
        self.infostr += '<ul class="tabs">'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-0" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-0\', \'nodeTabContent-0\')">Info</button>'
        self.infostr += '<li class="nodetablinks" id="nodeTabSelect-1" onclick="nocInfo.selectNodeTab(\'nodeTabSelect-1\', \'nodeTabContent-1\')">Config TDM</button>'
        self.infostr += '</ul>'

        # Create info tab
        self.infostr += '<div id="nodeTabContent-0" class="nodetabcontent">'.format(self.nodeid)
        self.infostr += '<center>'
        self.infostr += '<table>'
        self.infostr += '<tr><th>TDM Endpoint</th><th style="width:90px;text-align:right">Sent</th><th style="width:90px;text-align:right">Received</th></tr>'
        for ep in range(self.num_tdm_ep):
            self.infostr += '<tr><td>EP {}:</td><td id="sent_ep_{}" style="text-align:right">sent</td><td id="rcvd_ep_{}" style="text-align:right">rec</td></tr>'.format(ep, ep, ep)
        self.infostr += '</table>'
        """
        HCTs can currently not receive any BE traffic as the endpoint is not
        enabled, therefore, displaying the amount of faulty BE packets received
        makes no sense.
        """
        #self.infostr += 'Faulty BE packets received: <span id="faulty_be">faulty</span>'
        self.infostr += '</div>'

        # TDM channel config box
        self.infostr += '<div id="nodeTabContent-1" class="nodetabcontent">'.format(self.nodeid)
        for ep in range(self.num_tdm_ep):
            self.infostr += '<table style="width:100%"><tr>'
            self.infostr += '<td width="30%">Channel to node <span id="channel_dest_{}">n/a</span></td>'.format(ep)
            self.infostr += '<td width="60%">Path 0: <span id="path_0_channel_{}">-</span></td>'.format(ep)
            self.infostr += '<td width="10%" align="right">'
            self.infostr += '<button id="btn_set_clr_ch_{}_path_0" type="submit" onclick="nocInfo.configureTDMpath({}, 0)"></button></td>'.format(ep, ep)
            self.infostr += '</tr><tr>'
            self.infostr += '<td width="30%"></td>'
            self.infostr += '<td width="60%">Path 1: <span id="path_1_channel_{}">-</span></td>'.format(ep)
            self.infostr += '<td width="10%" align="right">'
            self.infostr += '<button id="btn_set_clr_ch_{}_path_1" type="submit" onclick="nocInfo.configureTDMpath({}, 1)"></button></td>'.format(ep, ep)
            self.infostr += '</tr></table>'
            if ep < self.num_tdm_ep - 1:
                self.infostr += '<hr noshade size=1>'
        self.infostr += '</div>'

    def reset(self):
        super().reset_stats()

    def update_stats(self, stats):
        super().update_stats(stats)
