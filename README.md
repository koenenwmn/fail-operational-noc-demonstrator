Fail-Operational NoC for Mixed-Critical MPSoC - Demonstrator
===

This demonstrator is intended to demonstrate the Fail-Operational NoC for
Mixed-Critical MPSoC developed at TUM-LIS.

General Structure
---
The demonstrator is based on the [OpTiMSoC](https://www.optimsoc.org/) Project.
This repository holds all source files that are needed to synthesize two
different systems:
- A tiled 4x4 system for a VCU108 Evaluation Board with a Virtex UltraScale FPGA
- A tiled 3x3 system for a Nexys Video Board with an Artix-7 FPGA

Additionally, the OpTiMSoC environment must be set up in order to build and use
the software necessary to interact with the demonstrator system.

The following directory tree is intended for the source code used in this
project:

```
.
+-- demonstrator_runner/                (demonstrator application(s) interfacing the target)
|   +-- applications/
|   |   +-- ped/                        (source code files for the pedestrian detection)
|   |
|   +-- demonstratorlib/                (general source code files for applications interfacing the target)
|   +-- demonstrator_runner.py          (the demonstrator runner application)
|
+-- external/                           (directory for external projects used by this project)
|   +-- install-build-deps-optimsoc.sh  (install script for project setup)
|   +-- install-build-deps-osd.sh       (install script for project setup)
|
+-- licenses/                           (licenses for data/source files from other projects used in this project)
|
+-- system_3x3_nexysVideo/              (necessary filed for the 3x3 system for the Nexys Video Board)
|   +-- src/
|   +-- system_3x3_nexysVideo.bit       (bitstream of the prebuilt 3x3 system)
|   +-- system_3x3_nexysVideo.tcl       (tcl script to regenerate Vivado project of 3x3 system)
|
+-- system_4x4_vcu108/                  (necessary filed for the 4x4 system for the VCU108 Board)
|   +-- src/
|   +-- system_4x4_vcu108.bit           (bitstream of the prebuilt 4x4 system)
|   +-- system_4x4_vcu108.tcl           (tcl script to regenerate Vivado project of 4x4 system)
|
+-- target_sw/                          (software running on the target)
|   +-- lct_traffic_app/                (application to generate and consume packet switched background traffic)
|   +-- lib_hybrid_mp_simple/           (library files for NoC traffic handling)
|   +-- ped_app/                        (pedestrian detection application)
|   +-- Makefile                        (Makefile to build all target software)
|
+-- venv/                               (virtual environment for demonstrator application, created during setup)
+-- README.md
+-- requirements.txt
+-- setup-project.sh                    (script to set up the demonstrator project)
```

Setup
===

To set up the environment the following steps are necessary:  
(Setup was tested under Ubuntu 22.04)
- Clone the project to a directory of your choice
- Run the setup script with `sudo ./setup-project.sh`
- In each new session, load the environment for OpTiMSoC with `source load_deps.sh`


Hardware Requirements
===

This repository provides two different demonstrator systems.
A 4x4 system for a VCU108 FBGA Board, and a 3x3 system vor a Nexys Video Board.  
Depending on which system you want to use there are different hardware
requirements in addition to the board itself.

For maximum communication bandwidth, the 4x4 system uses USB3.0 for communication with the host-PC.  
This requires two additional components:
- the [CYUSB3KIT-003 EZ-USB™ FX3 SuperSpeed explorer kit](https://www.infineon.com/cms/de/product/evaluation-boards/cyusb3kit-003/)
- and the [corresponding CYUSB3ACC-005 FMC interconnect board](https://www.infineon.com/cms/en/product/evaluation-boards/cyusb3acc-005/)

If the FX3 is used, the explorer kit must first be programmed with the correct firmware.  
After the setup script is sucessfully run, the firmware and documentation how this is done can be found in:  
`./external/optimsoc-src/external/glip/src/backend_cypressfx3/`

If the FX3 is not used, the system can also use the on-board USB-UART bridge, or a USB-UART bridge connected to a PMOD connector.  
This can be done by setting the `HOST_IF` and `UART0_SOURCE` parameters on toplevel as described in the source code.  
The prebuilt bitstream of the 4x4 system, however, uses USB3.0.

The prebuilt bitstream of the 3x3 system is configured to use a USB-UART bridge connected to the lower row of PMODB ([this bridge](https://digilent.com/shop/pmod-usbuart-usb-to-uart-interface/) was used for testing).  
The on-board USB-UART bridge of the Nexys Video Board should work just as fine. Unfortunately, the one of my board is broken and until I get a replacement I cannot test this.


Synthesizing a System
===

To synthesize a system, change into the corresponding directory (`system_3x3_nexysVideo` or `system_4x4_vcu108`).  
Open Vivado and source the *.tcl script to regenerate the project.  
The prebuilt bitstreams were created with Vivado 2019.2. If a newer version is used some of the Xilinx IPs might need to be updated.


Starting the Demonstrator
===

- Load the necessary dependencies:  
`source load_deps.sh`
- If using the FX3: connect the FX3 USB adapter board to the FMC2 connector on the VCU108/Nexys Video (the one next to the Ethernet port for the VCU108) but don't connect the USB cable to the host PC.
- Load the bitstream to the FPGA.
- If using the FX3: connect the FX3 USB adapter board to a USB3 port of the host PC.
- If using a USB-UART bridge: connect it to a free USB port of the host-PC and make sure you have read and write permissions to /dev/ttyUSB*
- Start the demonstrator application:
    - When using the FX3:  
`./venv/bin/python3 demonstrator_runner/demonstrator_runner.py`
    - When using a USB-UART bridge:  
`./venv/bin/python3 demonstrator_runner/demonstrator_runner.py -b uart`
- Once the control UI opens up, open a browser and connect to: `localhost:5000` to show the monitor UI  
You should see the NoC monitor window and the two utilization graphs slowly updating from right to left.
- In the control window (the one that opened when starting the demonstrator runner) press 'Program Cores' to load the target applications onto the cores.
- Press 'Start System' to configure the TDM channels and start the cores.
- Press 'Start Training' then 'Load SVM' and select the pretrained sample to send it to the critical cores.
- Press 'Run', have fun!


Troubleshooting
===

Sometimes, the demonstrator gets stuck when loading the target application to
the cores. If that is the case, press ctrl-c in the terminal and(!) close the
application window.  
Start the demonstrator runner and try again. If the problem persists, reset
the board and flash the bitstream again.  
Do the same in case the utilization graphs in the monitoring UI don't update.
