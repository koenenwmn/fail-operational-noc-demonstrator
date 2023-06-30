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

Definition of constants for the demonstrator runner.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

# Target architecture
MAPPING = {"2x2": ["LCT", "HCT",
                   "I/O", "LCT"],

           "3x3": ["LCT", "HCT", "HCT",
                   "I/O", "LCT", "LCT",
                   "LCT", "HCT", "LCT"],

           "4x4": ["HCT", "LCT", "HCT", "LCT",
                   "LCT", "HCT", "LCT", "HCT",
                   "I/O", "LCT", "HCT", "LCT",
                   "LCT", "HCT", "LCT", "LCT"]}

# Value used for empty slots in a slot table.
EMPTY = 15

# Connection options
DEFAULT_IF = "cypressfx3"
GLIP_OPTIONS = {"cypressfx3": {},
                "tcp": {"hostname": "localhost", "port": "23000"},
                "uart": {"device": "/dev/ttyUSB0", "speed": "3000000"}}
LOCALHOST = "tcp://0.0.0.0:9537"


# OSD constants
OSD_VENDOR_TUMLIS = 4

OSD_TYPE_NOC_BRIDGE = 4
OSD_TYPE_CTRL_MOD = 5
OSD_TYPE_SM = 6

OSD_MODULE_VENDOR_LIST = {
    0x0000: ("UNKNOWN", "UNKNOWN"),
    0x0001: ("OSD", "The Open SoC Debug Project"),
    0x0002: ("OPTIMSOC", "The OpTiMSoC Project"),
    0x0003: ("LOWRISC", "LowRISC"),
    0x0004: ("TUMLIS", "TUM LIS")
}
OSD_MODULE_TYPE_STD_LIST = {
    0x0000: ("UNKNOWN", "UNKNOWN"),
    0x0001: ("SCM", "Subnet Control Module"),
    0x0002: ("DEM_UART", "Device Emulation Module UART"),
    0x0003: ("MAM", "Memory Access Module"),
    0x0004: ("STM", "System Trace Module"),
    0x0005: ("CTM", "Core Trace Module")
}
OSD_MODULE_TYPE_TUMLIS_LIST = {
    0x0000: ("UNKNOWN", "UNKNOWN"),
    0x0001: ("CEG", "Core Event Generator"),
    0x0002: ("DIP", "Diagnosis Processor"),
    0x0003: ("CNT", "Event Counter"),
    0x0004: ("NOC_BRIDGE", "DI NoC Bridge"),
    0x0005: ("NCM", "NoC Control Module"),
    0x0006: ("SM", "Bus Surveillance Module")
}
