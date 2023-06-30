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

This class creates a Flask server that provides the GUI to monitor the NoC and
interact with the system.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import logging
import random
import os
from flask import Flask, render_template, send_from_directory
from flask_socketio import SocketIO
from threading import Thread
from demonstratorlib.constants import *
from demonstratorlib.path_util import *
from applications.ped.node_info import *


# Display utilization in total cycles or percentage
UTIL_PERCENT = True

# These constants are used for display in the monitor GUI
UTIL_FACTOR_BE = 20 if UTIL_PERCENT else 1000000
UTIL_FACTOR_TDM = 0.005 if UTIL_PERCENT else 1500 # Is multiplied by 2 further down for 4x4 system
HCTFREQ = 75
LCTFREQ = 50
NOCFREQ = 100
# Clock counter for NoC utilization data
CLK_UTIL = (NOCFREQ * 1000000) // 4
CLK_UTIL_SIM = CLK_UTIL // 5
# Set by monitor class, read from device by control class.
UPDATE_TIME = None
X_DIM = None
Y_DIM = None

BE = 'be'
TDM = 'tdm'
ERROR = 'error'
INJERROR = 'injectError'
INFO = 'info'
PID = 'pid'

MOD = None

app = Flask(__name__)
app.config['SECRET_KEY'] = 'secret'
socketio = SocketIO(app)
# Don't show log messages in console
log = logging.getLogger('werkzeug')
log.setLevel(logging.ERROR)

# Global reference to control class
monitor = None

@app.route('/')
def sessions():
    monitor.client_ready = False
    return render_template('index.html')

@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.route_path, 'static/images'), 'favicon.ico', mimetype='image/vnd.microsoft.icon')

@socketio.on('connect')
def test_connect():
    print("client connected")

@socketio.on('stop server')
def stop_server():
    socketio.stop()

@socketio.on('request')
def request(json, methods=['GET', 'POST']):
    if json['req'] == 'init':
        init = {}
        init['x'] = X_DIM
        init['y'] = Y_DIM
        init['updateTime'] = UPDATE_TIME
        init['utilFactor'] = {"be": UTIL_FACTOR_BE, "tdm": UTIL_FACTOR_TDM}
        init['generalInfo'] = monitor.general_info
        init['linkInfo'] = monitor.link_info
        init['nodeTypes'] = monitor.node_types
        init['utilPercent'] = UTIL_PERCENT
        init['nodeInit'] = monitor.create_node_init()
        init['connections'] = monitor.create_tdm_dict()
        socketio.emit('init', init)

@socketio.on('ready')
def clientReady():
    monitor.client_ready = True

@socketio.on('clr_path')
def clearPath(json, methods=['GET', 'POST']):
    monitor.clear_path(json['chid'], json['path_idx'])

@socketio.on('setup_path')
def setupPath(json, methods=['GET', 'POST']):
    monitor.setup_path(json['chid'], json['path_idx'], json['path'])

@socketio.on('injectFault')
def injectFault(json, methods=['GET', 'POST']):
    monitor.update_faults(json['node'], json['link'], json['inject'])

@socketio.on('setLCTDest')
def setLCTDest(json, methods=['GET', 'POST']):
    monitor.update_lct_dest(json['node'], json['dest'], json['set'])

@socketio.on('set burst')
def setBurst(json, methods=['GET', 'POST']):
    monitor.set_burst(json['node'], json['cmd'])

@socketio.on('set proc delay')
def setProcDelay(json, methods=['GET', 'POST']):
    monitor.set_proc_delay(json['node'], json['cmd'])

def flaskThread():
    socketio.run(app, debug=False, port=5000, host="localhost")
    print("{}: Terminating server..".format(MOD))


class MonitorGUI():
    def __init__(self, ctrl_mod, io_tile, sm_client, simulation):
        global MOD, UPDATE_TIME, X_DIM, Y_DIM, HCTFREQ
        MOD = self.__class__.__name__
        self.ctrl_mod = ctrl_mod
        self.io_tile = io_tile
        self.sm_client = sm_client
        self.simulation = simulation
        X_DIM = self.ctrl_mod.x_dim
        Y_DIM = self.ctrl_mod.y_dim
        # hack: the HCT of the 3x3 system currently only runs with 50MHz.
        # This should be solved differently in the future..
        if X_DIM == 3:
            HCTFREQ = 50
        self.slot_table_size = self.ctrl_mod.slot_table_size
        self.num_tdm_ep = []
        for n in range(X_DIM * Y_DIM):
            self.num_tdm_ep.append(self.sm_client.get_num_tdm_ep(n))
        self.ctrl_mod.set_num_tdm_ep(self.num_tdm_ep)
        UPDATE_TIME = CLK_UTIL // (NOCFREQ * 1000)
        # Saveguard to prohibit too small time, mainly for simulation
        UPDATE_TIME = 200 if UPDATE_TIME < 200 else UPDATE_TIME
        if UTIL_PERCENT:
            self.percent_div = ((NOCFREQ * 1000000) / (1000 / UPDATE_TIME)) / 100
        # Reference to PED app. Used to send config data to tiles.
        # Set by PED app.
        self.ped = None

        self._initialize_variables()

        # Set event handler for surveillance modules
        self.sm_client.set_stat_handler(self.sm_stats_handler)

        # Avoid sending data to client if not ready
        self.client_ready = False

        # Set global reference to self
        global monitor
        monitor = self
        print("{}: Starting server thread".format(MOD))
        self.flask_thread = Thread(target=flaskThread)
        self.flask_thread.daemon = True
        self.flask_thread.start()

        # Register receive handlers and activate monitoring unless simple ncm
        # is used
        if self.ctrl_mod.simple_ncm == 0:
            self.ctrl_mod.register_util_handler(self.util_handler)
            self.ctrl_mod.register_fd_handler(self.fd_handler)
            if self.simulation:
                self.ctrl_mod.activate_monitoring(CLK_UTIL_SIM)
            else:
                self.ctrl_mod.activate_monitoring(CLK_UTIL)

    def create_node_init(self):
        """
        Create the list with the initial node info for the UI.
        """
        nodeInit = []
        for n in range(len(self.node_info)):
            # Create a dict for each node
            init = {}
            init["info"] = self.node_info[n].get_info_str()
            init["stats"] = self.node_info[n].get_stats()
            init["num_tdm_ep"] = self.num_tdm_ep[n]
            if self.node_info[n].type == "LCT":
                init["be_config"] = self.node_info[n].get_be_conf()
            nodeInit.append(init)
        return nodeInit

    def create_tdm_dict(self):
        """
        Create a dictinary with path and channel information for the UI.
        """
        # Nodes use x-y indices on client side
        tdm_nodes = []
        for x in range(X_DIM):
            tdm_nodes.append([])
            for y in range(Y_DIM):
                tdm_nodes[-1].append(self.tdm_nodes[y*X_DIM+x])
        tdm_connections = {}
        tdm_connections['paths'] = self.ctrl_mod.create_path_dict()
        tdm_connections['channels'] = self.ctrl_mod.create_channel_dict()
        tdm_connections['nodes'] = tdm_nodes

        return tdm_connections

    def _initialize_variables(self):
        # List with node info objects and corresponding info strings for the UI
        self.node_info = []
        # List to keep track of stats for each node (sent/received packets)
        self.node_stats = []
        topology = "{}x{}".format(X_DIM, Y_DIM)
        # Populate lists
        for n in range(len(MAPPING[topology])):
            if MAPPING[topology][n] == "LCT":
                self.node_info.append(NodeInfoLCT(n, X_DIM, Y_DIM, self.num_tdm_ep[n]))
            elif MAPPING[topology][n] == "HCT":
                self.node_info.append(NodeInfoHCT(n, X_DIM, Y_DIM, self.num_tdm_ep[n]))
            elif MAPPING[topology][n] == "I/O":
                self.node_info.append(NodeInfoIO(n, X_DIM, Y_DIM, self.num_tdm_ep[n]))
            else:
                self.node_info.append(NodeInfo(n, X_DIM, Y_DIM, self.num_tdm_ep[n]))
            self.node_stats.append({'tdm_sent': [], 'tdm_rcvd': [], 'be_sent': [], 'be_rcvd': [], 'be_faults': 0})
            for _ in range(self.num_tdm_ep[n]):
                self.node_stats[-1]['tdm_sent'].append(0)
                self.node_stats[-1]['tdm_rcvd'].append(0)
            for _ in range(X_DIM * Y_DIM):
                self.node_stats[-1]['be_sent'].append(0)
                self.node_stats[-1]['be_rcvd'].append(0)
        self.node_types = MAPPING[topology]
        # List to keep track of TDM channels
        self.tdm_channels = []
        # List to keep track which nodes are source or destination of a TDM
        # channel
        self.tdm_nodes = []
        for _ in range(len(MAPPING[topology])):
            self.tdm_nodes.append([])
        # Create general info string
        self.general_info = """<center><b>TUM - LIS: Hybrid NoC Monitor</b><br>
Critical cores @ {}MHz<br>
Non-critical cores @ {}MHz<br>
NoC @ {}MHz<br>
Slot table size: {}</center>
""".format(HCTFREQ, LCTFREQ, NOCFREQ, self.slot_table_size)
        # Initialize util dict
        self.util_data = {}
        self.util_data[TDM] = []
        self.util_data[BE] = []
        for _ in range(X_DIM * Y_DIM):
            self.util_data[TDM].append([])
            self.util_data[BE].append([])
            for _ in range(8):
                self.util_data[TDM][-1].append(0)
                self.util_data[BE][-1].append(0)
        # Initialize util index list.
        # This list determines the active links of each node
        self._util_idx = []
        for node in range(X_DIM * Y_DIM):
            self._util_idx.append([])
            curr_x = node % X_DIM
            curr_y = node // X_DIM
            # Add links to neighboring routers
            if curr_y != 0:
                self._util_idx[-1].append(0)
            if curr_x != X_DIM - 1:
                self._util_idx[-1].append(1)
            if curr_y != Y_DIM - 1:
                self._util_idx[-1].append(2)
            if curr_x != 0:
                self._util_idx[-1].append(3)
            # Add links to local tile
            for link in range(4,8):
                self._util_idx[-1].append(link)
        # Initialize link info dict
        self.link_info = {}
        self.link_info[ERROR] = []
        self.link_info[INJERROR] = []
        self.link_info[INFO] = []
        self.link_info[PID] = []
        for n in range(X_DIM * Y_DIM):
            self.link_info[ERROR].append([])
            self.link_info[INJERROR].append([])
            self.link_info[INFO].append([])
            self.link_info[PID].append([])
            for l in range(8):
                self.link_info[ERROR][-1].append(False)
                self.link_info[INJERROR][-1].append(False)
                self.link_info[INFO][-1].append('<center><b>Router {} Link {}</b><br>Reserved slots: []</center>'.format(n, l))
                self.link_info[INFO][-1][-1] += '<br><br><center><span id="link_fault" style="color:red"></span></center>'
                self.link_info[PID][-1].append([])
        # Multiply UTIL_FACTOR_TDM by 2 for 4x4 mapping since the amount of TDM
        # traffic is higher. Simple hack for now, if more system configuration
        # are introduced, a different approach should be implemented.
        if topology == "4x4":
            global UTIL_FACTOR_TDM
            UTIL_FACTOR_TDM *= 2

    def _reset_variables(self):
        # Reset NodeInfo
        topology = "{}x{}".format(X_DIM, Y_DIM)
        for n in range(len(MAPPING[topology])):
            self.node_info[n].reset()
        # Reset util data
        for n in range(X_DIM * Y_DIM):
            for l in range(8):
                self.util_data[TDM][n][l] = 0
                self.util_data[BE][n][l] = 0
        # Reset TDM channels
        self.tdm_channels = []
        for n in range(len(MAPPING[topology])):
            self.tdm_nodes[n] = []
        # Reset link info
        for n in range(X_DIM * Y_DIM):
            for l in range(8):
                self.link_info[ERROR][n][l] = False
                self.link_info[INJERROR][n][l] = False
                self.link_info[INFO][n][l] = '<center><b>Router {} Link {}</b><br>Reserved slots: []</center>'.format(n, l)
                self.link_info[INFO][n][l] += '<br><br><center><span id="link_fault" style="color:red"></span></center>'
                self.link_info[PID][n][l] = []
        if self.client_ready:
            socketio.emit('update link info', self.link_info)

    def _intialize_sm(self):
        for node in range(X_DIM * Y_DIM):
            if self.node_info[node].type == LCT:
                self.sm_client.set_dimensions(node, X_DIM, Y_DIM)
                seed = random.getrandbits(32)
                while seed == 0:
                    seed = random.getrandbits(32)
                self.sm_client.set_seed(node, seed)

    def reset(self):
        self.sm_client.deactivate_surveillance()
        for c in range(len(self.tdm_channels)):
            self._delete_tdm_channel(self.tdm_channels[c])
        self.ctrl_mod.reset()
        self._reset_variables()
        self._update_link_info()

    def stop_server(self):
        socketio.emit('stop server', True)

    def configure_basic_demo_paths(self):
        system = "{}x{}".format(X_DIM, Y_DIM)
        if system not in MAPPING:
            print("{}: No mapping defined for {} System!".format(MOD, system))
            return False
        else:
            success = True
            for dest in range(len(MAPPING[system])):
                if MAPPING[system][dest] == "HCT":
                    # Configure TDM channels to and from HCT
                    io_to_dest = self._setup_tdm_channel(self.io_tile, dest)
                    dest_to_io = self._setup_tdm_channel(dest, self.io_tile)
                    if not io_to_dest or not dest_to_io:
                        print("{}: Failed to setup TDM channels.".format(MOD))
                        success = False

            self._update_link_info()
            return success

    def _setup_tdm_channel(self, src, dest):
        chid = self.ctrl_mod.create_tdm_channel(src, dest)
        if chid < 0:
            print("{}: Error! could not create TDM channel from tile {} to tile {}. Error code '{}'.".format(MOD, src, dest, chid))
            return False
        self.tdm_channels.append(chid)
        # Associate channel with both source and destination node
        if chid not in self.tdm_nodes[src]:
            self.tdm_nodes[src].append(chid)
        if chid not in self.tdm_nodes[dest]:
            self.tdm_nodes[dest].append(chid)
        return True

    def _delete_tdm_channel(self, chid):
        self.ctrl_mod.delete_tdm_channel(chid)
        for n in range(X_DIM * Y_DIM):
            if chid in self.tdm_nodes[n]:
                self.tdm_nodes[n].remove(chid)

    def _update_link_info(self):
        """
        Update the link info text with the currently reserved slots.
        """
        for n in range(X_DIM * Y_DIM):
            for l in range(8):
                reserved = []
                paths = []
                ni = 0 if l < 6 else 1
                link = l if ni == 0 else l - 6
                for s in range(self.slot_table_size):
                    pid = self.ctrl_mod.tdm_info.table_config[n][ni][link][s][1]
                    if pid is not None:
                        reserved.append([s, pid])
                        if pid not in paths:
                            paths.append(pid)
                # Add offset of 1 for all slots other than injecting ones.
                # This is to have 1 cycle delay between the injecting links and
                # the next link in the GUI (the reserved slot shows when a flit
                # appears on a link rather than when when a register reads a
                # flit from the previous link).
                if ni == 0:
                    for s in range(len(reserved)):
                        reserved[s][0] = (reserved[s][0] + 1) % self.slot_table_size
                # Create info string with mouse-over for each reserved slot
                reserved_str = ''
                for r in range(len(reserved)):
                    slot = reserved[r][0]
                    pid = reserved[r][1]
                    path = self.ctrl_mod.tdm_paths[pid]
                    src = path.path[0]
                    dest = path.path[-1]
                    path_idx = path.path_idx
                    reserved_str += '<span title="Tile {} to tile {}, path {}.">{}'.format(src, dest, path_idx, slot)
                    if r < (len(reserved)-1):
                        reserved_str += ','
                    reserved_str += '</span>'
                self.link_info[INFO][n][l] = "<center><b>Router {} Link {}</b><br>Reserved slots: [{}]</center>".format(n, l, reserved_str)
                self.link_info[INFO][n][l] += '<br><br><center><span id="link_fault" style="color:red"></span></center>'
                self.link_info[PID][n][l] = paths
        if self.client_ready:
            socketio.emit('update link info', self.link_info)
            socketio.emit('update connections', self.create_tdm_dict())

    def clear_path(self, chid, path_idx):
        self.ctrl_mod.remove_path_from_channel(chid, path_idx)
        self._update_link_info()

    def setup_path(self, chid, path_idx, path):
        # Convert client [x,y]-notation to server node-notation
        path = [(hop[1]*X_DIM+hop[0]) for hop in path]
        retval = self.ctrl_mod.add_path_to_channel(chid, path_idx, path)
        if retval == 0:
            self._update_link_info()
        else:
            if retval == 1:
                socketio.emit('display error', "The selected path overlaps with the alternative path!")
            else:
                socketio.emit('display error', "The selected path could not be configured!")

    def update_faults(self, node, link, set_fault=True):
        """
        Sets or clears a fault on a specified link.
        """
        self.link_info[INJERROR][node][link] = set_fault
        n, l = self._in_link_to_out_link(node, link)
        self.ctrl_mod.configure_faults(n, l, set_fault)
        if self.client_ready:
            socketio.emit('update link info', self.link_info)

    def update_lct_dest(self, node, dest, set):
        """
        Sets or clears a destination for an LCT.
        """
        self.node_info[node].set_dest(dest, set)
        # Send new config to tile if the app is running
        if self.ped.is_reset == False and self.ped.be_traffic_active:
            self.sm_client.set_dest_list(node, self.node_info[node].get_dest_list())

    def set_burst(self, node, cmdstr):
        """
        Defines the burst size of an LCT.
        """
        if self.node_info[node].type != LCT:
            print("{}: Error in 'setBurst'. Node {} is not an LCT!".format(MOD, node))
            return
        min, max = self._parse_range(cmdstr)
        if max is not None:
            self.node_info[node].set_burst(max, min)
            # Send config to tile if the app is running
            if self.ped.is_reset == False and self.ped.be_traffic_active:
                self.sm_client.set_min_burst(node, min)
                self.sm_client.set_max_burst(node, max)
            # Send parsed config back to UI
            resp = {"x": node % X_DIM, "y": node // X_DIM, "nodeConf": self.node_info[node].get_be_conf()}
            socketio.emit('update node conf be', resp)

    def set_proc_delay(self, node, cmdstr):
        """
        Defines the processing delay of a processing element.
        """
        min, max = self._parse_range(cmdstr)
        if max is not None:
            self.node_info[node].set_proc_delay(max, min)
            # Send config to tile if it is an LCT and the app is running
            if self.node_info[node].type == LCT and self.ped.is_reset == False and self.ped.be_traffic_active:
                self.sm_client.set_min_delay(node, min)
                self.sm_client.set_max_delay(node, max)
            # Send parsed config back to UI
            resp = {"x": node % X_DIM, "y": node // X_DIM, "nodeConf": self.node_info[node].get_be_conf()}
            socketio.emit('update node conf be', resp)

    def enable_sm(self):
        self._intialize_sm()
        self.sm_client.activate_surveillance()

    def enable_be(self):
        for node in range(X_DIM * Y_DIM):
            if self.node_info[node].type == LCT:
                self.sm_client.set_dest_list(node, self.node_info[node].get_dest_list())
                min, max = self.node_info[node].get_proc_delay()
                self.sm_client.set_min_delay(node, min)
                self.sm_client.set_max_delay(node, max)
                min, max = self.node_info[node].get_burst()
                self.sm_client.set_min_burst(node, min)
                self.sm_client.set_max_burst(node, max)

    def disable_be(self):
        for node in range(X_DIM * Y_DIM):
            if self.node_info[node].type == LCT:
                self.sm_client.set_max_burst(node, 0)

    def _parse_range(self, cmdstr):
        # Remove spaces
        cmdstrnows = cmdstr.strip().replace(" ", "")
        range = cmdstrnows.split("-")
        if len(range) > 2:
            print("{}: Error. Range can only contain up to 2 elements!".format(MOD))
        else:
            try:
                min = int(range[0])
                max = min if len(range) == 1 else int(range[1])
                if min is not None and min > max:
                    print("{}: Error. 'min' value ({}) is larger than 'max' value ({})!".format(MOD, min, max))
                else:
                    return min, max
            except Exception:
                print("{}: Error while parsing range for: '{}'!".format(MOD, cmdstr))
        return None, None

    def _in_link_to_out_link(self, inode, ilink):
        """
        Translates the node:link notation of incoming links to the one of
        outgoing links and vice versa (e.g. in link 3 of node 1 is out link 1 of
        node 0).
        Does not perform validity checks.
        """
        onode = inode
        olink = ilink
        if ilink == 0:
            onode -= X_DIM
            olink = 2
        elif ilink == 1:
            onode += 1
            olink = 3
        elif ilink == 2:
            onode += X_DIM
            olink = 0
        elif ilink == 3:
            onode -= 1
            olink = 1
        elif ilink == 4:
            olink = 6
        elif ilink == 5:
            olink = 7
        elif ilink == 6:
            olink = 4
        elif ilink == 7:
            olink = 5
        return onode, olink

    def _link_exists(self, node, link):
        if link < 0 or link > 7:
            return False
        x = node % X_DIM
        y = node // X_DIM
        exists = True
        if x == 0:
            exists = False if link == 3 else exists
        if x == X_DIM - 1:
            exists = False if link == 1 else exists
        if y == 0:
            exists = False if link == 0 else exists
        if y == Y_DIM - 1:
            exists = False if link == 2 else exists
        return exists

    def _set_link_faults(self, node, node_faults):
        """
        Updates the detected faults.
        """
        for link in range(8):
            if not self._link_exists(node, link):
                continue
            n, l = self._in_link_to_out_link(node, link)
            fault = True if (node_faults >> link) & 0x1 else False
            self.link_info[ERROR][n][l] = True if (node_faults >> link) & 0x1 else False

    def sm_stats_handler(self, node_update):
        node = node_update['node']
        self.node_info[node].update_stats(node_update)

    def fd_handler(self, payload):
        """
        Process the fault detection information from the system.
        """
        node = payload[0] >> 2
        idx = 1
        while node < X_DIM * Y_DIM and idx < len(payload):
            node_faults = payload[idx] & 0xff
            self._set_link_faults(node, node_faults)
            node += 1
            if node < X_DIM * Y_DIM:
                node_faults = (payload[idx] >> 8) & 0xff
                self._set_link_faults(node, node_faults)
                node += 1
                idx += 1
        if self.client_ready:
            socketio.emit('update link info', self.link_info)

    def util_handler(self, payload):
        """
        Processes the utilization data from the system.
        """
        trans_mode = (payload[0] >> 2) & 0b11
        word = (payload[0] >> 4) & 0b1
        node = (payload[0] >> 5)
        # Delete first list element to only keep util info
        del payload[0]
        for link in range(len(payload)):
            # TDM util data
            if trans_mode == 0:
                if word == 0:
                    self.util_data[TDM][node][self._util_idx[node][link]] = payload[link]
                else:
                    self.util_data[TDM][node][self._util_idx[node][link]] |= payload[link] << 16
                    # Calculate utilization in percent
                    if UTIL_PERCENT:
                        self.util_data[TDM][node][self._util_idx[node][link]] /= self.percent_div
            # BE util data
            else:
                if word == 0:
                    self.util_data[BE][node][self._util_idx[node][link]] = payload[link]
                else:
                    self.util_data[BE][node][self._util_idx[node][link]] |= payload[link] << 16
                    # Calculate utilization in percent
                    if UTIL_PERCENT:
                        self.util_data[BE][node][self._util_idx[node][link]] /= self.percent_div
        # Update Display after BE info of node 8 has been received
        if trans_mode == 1 and node == (X_DIM * Y_DIM) - 1 and word == 1:
            if self.client_ready:
                socketio.emit('update util', self.util_data)

                # Update of the node stats is currently tied to the util data to
                # achieve the same interval.
                stats = []
                for n in range(len(self.node_info)):
                    stats.append(self.node_info[n].get_stats())
                socketio.emit('update node stat', stats)
