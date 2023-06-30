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

Utility methods used to connect to and control target system.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import subprocess
import psutil
import osd
from time import sleep
from demonstratorlib.constants import *

# Hostctrl, gateway, and hostmod instances
_hostctrl = None
_gw = None
_hostmod = None


def connect_target(log, backend):
    global _hostctrl, _gw, _hostmod
    # Start host controller
    _hostctrl = osd.Hostctrl(log, LOCALHOST)
    _hostctrl.start()

    # Start device gateway
    options = GLIP_OPTIONS[backend]
    _gw = osd.GatewayGlip(log, LOCALHOST, 0, backend, options)
    _gw.connect()
    assert(_gw.is_connected())

    # Create host module to enumerate system
    _hostmod = osd.Hostmod(log, LOCALHOST)
    _hostmod.connect()
    assert(_hostmod.is_connected())
    #print("hostmod DIADDR: {}".format(_hostmod.diaddr))

    return _hostmod.get_modules(0)

def disconnect_target(stm_loggers):
    # Tear down
    #print("Ending observation, shutting down")
    # STM loggers
    for l in stm_loggers:
        l.stop()
        l.disconnect()
        assert(not l.is_connected())

    # Host module
    _hostmod.disconnect()
    assert(not _hostmod.is_connected())

    # Gateway
    _gw.disconnect()
    assert(not _gw.is_connected())

    # Host controller
    _hostctrl.stop()

def load_memory(log, args, x_dim, y_dim, verify=False):
    # Load program memories
    memaccess = osd.MemoryAccess(log, LOCALHOST)
    memaccess.connect()
    memaccess.cpus_stop(0)

    memories = memaccess.find_memories(0)

    print("Loading memories")
    # Tile - memory index offset in case not all tiles have a memory (I/O Tile)
    offset = 0
    topology = "{}x{}".format(x_dim, y_dim)
    for i in range(len(memories)):
        # Increase offset if tile has no memory
        while MAPPING[topology][i+offset] == "I/O":
            offset += 1
        if MAPPING[topology][i+offset] == "LCT":
            elf = args.lct_elf
        elif MAPPING[topology][i+offset] == "HCT":
            elf = args.hct_elf
        if elf != "":
            print("  Memory of tile {}".format(i+offset))
            memaccess.loadelf(memories[i], elf, verify)

    print("Starting CPUs")
    memaccess.cpus_start(0)
    memaccess.disconnect()

def _get_module_name(vendor, type):
    if vendor == 1 and OSD_MODULE_TYPE_STD_LIST[type]:  # vendor == OSD
        return OSD_MODULE_TYPE_STD_LIST[type]

    if vendor == 4 and OSD_MODULE_TYPE_TUMLIS_LIST[type]:  # vendor == TUMLIS
        return OSD_MODULE_TYPE_TUMLIS_LIST[type]

    return ("UNKNOWN", "Unknown module")

def enumerate_modules(modules):
    print("Modules in Demonstrator")
    for module in modules:
        print("  {}.{}: {} {} v{} ({}.{})".format(
              0,
              module['addr'],
              OSD_MODULE_VENDOR_LIST[module['vendor']][0],
              _get_module_name(module['vendor'], module['type'])[0],
              module['version'],
              module['vendor'],
              module['type']))

def setup_stm_logging(log, modules):
    stm_loggers = []
    print("Setting up system trace loggers")
    stm_mod_addrs = [m['addr'] for m in modules if m['vendor'] == 0x0001 and m['type'] == 0x0004]
    for stm_mod_addr in stm_mod_addrs:
        print("  DI addr {}".format(stm_mod_addr))
        l = osd.SystraceLogger(log, LOCALHOST, stm_mod_addr)
        l.sysprint_log = 'stdout.{:03d}.log'.format(stm_mod_addr)
        l.event_log = 'events.{:03d}.log'.format(stm_mod_addr)
        l.connect()
        l.start()
        stm_loggers.append(l)
    return stm_loggers

def wait_for_sim_proc(proc):
    if proc:
        # Get pid from process name
        pid = int(subprocess.run(['pgrep', proc], stdout=subprocess.PIPE).stdout)
        print("Wait for simulation process to finish (pid: {}).".format(pid))
        while psutil.pid_exists(pid):
            sleep(1)
    else:
        sleep(SIM_EXEC_TIME_SEC)

class SystemManager():
    def __init__(self, log, args, x_dim, y_dim, verify=False):
        self.hm = osd.MemoryAccess(log, LOCALHOST)
        self.hm.connect()
        self.args = args
        self.verify = verify
        self.cpus_running = True
        self.x_dim = x_dim
        self.y_dim = y_dim

        # Load memories
        #self.load_memories()

    def stop_cpus(self):
        print("{}: Stopping CPUs".format(self.__class__.__name__))
        self.hm.cpus_stop(0)
        self.cpus_running = False

    def start_cpus(self):
        print("{}: Starting CPUs".format(self.__class__.__name__))
        self.hm.cpus_start(0)
        self.cpus_running = True

    def reset_system(self):
        print("{}: Resetting System".format(self.__class__.__name__))
        # Set both sys_rst and cpu_rst for 100ms then clear sys_rst
        _hostmod.reg_write(3, 0, 0x204)
        sleep(0.1)
        _hostmod.reg_write(2, 0, 0x204)
        sleep(0.1)

    def load_memories(self):
        if self.cpus_running:
            self.stop_cpus()

        memories = self.hm.find_memories(0)

        print("{}: Loading memories".format(self.__class__.__name__))
        # Tile - memory index offset in case not all tiles have a memory (I/O Tile)
        offset = 0
        topology = "{}x{}".format(self.x_dim, self.y_dim)
        for i in range(len(memories)):
            # Increase offset if tile has no memory
            while MAPPING[topology][i+offset] == "I/O":
                offset += 1
            if MAPPING[topology][i+offset] == "LCT":
                elf = self.args.lct_elf
            elif MAPPING[topology][i+offset] == "HCT":
                elf = self.args.hct_elf
            if elf != "":
                print("  Memory of tile {}".format(i+offset))
                self.hm.loadelf(memories[i], elf, self.verify)
        print("{}: Memories loaded".format(self.__class__.__name__))
