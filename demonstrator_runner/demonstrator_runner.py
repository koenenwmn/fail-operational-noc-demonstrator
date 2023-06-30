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

This is the host application for the Fail-Operational NoC Demonstrator.

It connects directly to the debug network of the target (FPGA or simulation).
The application starts a GUI for the pedestrian detection as well as a flask
server that can be connected to with a browser (localhost:5000) to monitor the
NoC of the system and interact with the system.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import logging
from time import sleep
import argparse
from demonstratorlib.constants import *
from demonstratorlib.system_util import *
from demonstratorlib.noc_gateway import NoCGateway
from demonstratorlib.ctrl_mod_cl import CtrlModClient
from applications.ped.ped_app import PedApp, DEFAULT_LCT_ELF, DEFAULT_HCT_ELF
from applications.ped.monitor_gui import MonitorGUI
from applications.ped.surveillance_mod_cl import SurveillanceModClient


def main(args):
    logging.basicConfig(format='%(levelname)s %(name)s %(asctime)s %(filename)s:%(lineno)s %(message)s',
                        level='INFO')
    log = osd.Log()

    print("Starting demonstrator runner...")
    # Setup connection and get list of all debug modules
    modules = connect_target(log, args.backend)
    # Enumerate system
    if True:
        enumerate_modules(modules)

    # Ensure there is no more than one 'DI NoC Bridge' and one 'NoC Control
    # Module' is the system
    noc_bridge = [m for m in modules if m['vendor'] == OSD_VENDOR_TUMLIS and m['type'] == OSD_TYPE_NOC_BRIDGE]
    assert(len(noc_bridge) == 1)
    ncm = [m for m in modules if m['vendor'] == OSD_VENDOR_TUMLIS and m['type'] == OSD_TYPE_CTRL_MOD]
    assert(len(ncm) == 1)

    # Get list of surveillance modules diaddr
    sm_diaddr = [m['addr'] for m in modules if m['vendor'] == OSD_VENDOR_TUMLIS and m['type'] == OSD_TYPE_SM]

    # STM logging. Only used when connected to an FPGA and not disabled
    stm_loggers = [] if not args.trace_stm or args.backend == 'tcp' else setup_stm_logging(log, modules)

    # Create control module client
    ctrl = CtrlModClient(log, LOCALHOST, ncm[0]['addr'])
    # Create system manager
    sys_manager = SystemManager(log, args, ctrl.x_dim, ctrl.y_dim, args.verify)
    # Create NoC gateway
    gw = NoCGateway(log, LOCALHOST, noc_bridge[0]['addr'], ctrl.x_dim, ctrl.y_dim)
    # Create surveillance hostmod
    sm_client = SurveillanceModClient(log, LOCALHOST, sm_diaddr, ctrl.x_dim, ctrl.y_dim)

    sleep(1)

    print("{}x{} system using {} routing for packet-switched traffic".format(
        ctrl.x_dim, ctrl.y_dim, "distributed" if gw.noc_bridge.dr_enabled == 1 else "source"))
    # Start GUI
    monitor = MonitorGUI(ctrl, gw.noc_bridge.tile, sm_client, args.backend == 'tcp')
    PedApp(gw, monitor, sys_manager, args.backend == 'tcp')
    # Application continues when PedApp is closed via GUI
    monitor.stop_server()
    monitor.flask_thread.join(5)

    disconnect_target(stm_loggers)
    sleep(1)

    print("Demonstrator runner finished.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Fail-Operational NoC Demonstrator Application')
    parser.add_argument("-b", "--backend",
                        help="glip backend to be used [default: %(default)s]",
                        default=DEFAULT_IF)
    parser.add_argument("-c", "--hct_elf",
                        help="path to elf file for high critical tiles [default: %(default)s]",
                        default=DEFAULT_HCT_ELF)
    parser.add_argument("-l", "--lct_elf",
                        help="path to elf file for low critical tiles [default: %(default)s]",
                        default=DEFAULT_LCT_ELF)
    parser.add_argument("--verify", action='store_true',
                        help="verify program after loading [default: %(default)s]")
    parser.add_argument("--trace_stm", action='store_true',
                        help="enable stm logging [default: %(default)s]")

    args = parser.parse_args()

    # Check for valid backend
    if args.backend not in GLIP_OPTIONS:
        print("Unknown backend: '{}'".format(args.backend))
    else:
        main(args)
