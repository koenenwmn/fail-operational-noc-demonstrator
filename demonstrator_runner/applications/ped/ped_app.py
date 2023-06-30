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

DI-NoC-Bridge client implementing the ped GUI.
The app loads the frames and distributes them to the HCTs on the FPGA. The
frames are buffered and then displayed together with the result.

Author(s):
  Max Koenen <max.koenen@tum.de>
  Simon Webhofer

"""

import tkinter as tk
import random
import os
import pickle
from time import sleep, time
from datetime import datetime
from demonstratorlib.noc_gateway_cl import NoCGatewayClient
from demonstratorlib.noc_gateway import *
from demonstratorlib.constants import *
from applications.ped.svm import SVM
from applications.ped.dialog_boxes import TrainingDialog, TRAIN_KNN, TRAIN_SVM, LOAD_SVM

# Software to load into target
DEFAULT_LCT_ELF = os.environ['DEMONSTRATOR_DIR'] + "/target_sw/lct_traffic_app/lct_traffic_app.elf"
DEFAULT_HCT_ELF = os.environ['DEMONSTRATOR_DIR'] + "/target_sw/ped_app/ped_app.elf"

STATS_UPDATE = 250
CLEANUP = 0

APP_TITLE = "TUM - LIS: Hybrid NoC Demonstrator"
IMG_DIR = os.environ['DEMONSTRATOR_DIR'] + "/demonstrator_runner/applications/ped/images"
SVM_DIR = os.environ['DEMONSTRATOR_DIR'] + "/demonstrator_runner/applications/ped/SVM_Data"
LOGOS = ["DensHit_Logo_1", "DensHit_Logo_2", "powered_by_optimsoc"]
PED_IMG_DIR = ["ped_examples", "non-ped_examples"]
POS = 0
NEG = 1
FPOS = 2
FNEG = 3
RESULT_IMG = {POS: "pos", NEG: "neg", FPOS: "false_pos", FNEG: "false_neg"}
MAX_IMG = [4799, 4999]
SHOW_RATE = True

IMG_HEIGHT = 36
IMG_WIDTH = 18

DEFAULT_NR_TRAIN_IMG = 50 # ped and non-ped each
DEFAULT_K = 7
DEFAULT_C = 0.1
DEFAULT_MAX_PASSES = 10

# Parameters for Hog Feature Extraction
# Defaults: cellsize=6, cells_per_block=2, nr_bins=9
# Cellsize should divide the image without rest
# These parameters are currently hard-coded on target side
CELLSIZE = 6
CELLS_PER_BLOCK = 2
NO_BINS = 9
NO_FEAT = NO_BINS * CELLS_PER_BLOCK ** 2 * (IMG_WIDTH // (CELLSIZE * CELLS_PER_BLOCK // 2) - 1) * (IMG_HEIGHT // (CELLSIZE * CELLS_PER_BLOCK // 2) - 1)

MOD = None


class Frame:
    """
    Helper class to store frames.
    """

    def __init__(self):
        self.img_no = None
        self.type = None
        self.detected = None
        self.core = None
        self.frame_no = None
        self.sent = time()


class PedApp(NoCGatewayClient):
    def __init__(self, gateway, monitor, sys_manager, simulation):
        super().__init__(gateway)
        self.gw.bind_traffic(self.cid, width=32)
        self.simulation = simulation
        global MOD, CLEANUP
        MOD = self.__class__.__name__
        CLEANUP = 0 if simulation else 5000

        self.monitor = monitor
        # Set reference to self in monitor module to allow sending of config data to tiles
        self.monitor.ped = self
        self.sys_manager = sys_manager

        self._create_tile_tables()

        # Initialize GUI and variables
        self.root = tk.Tk()
        # Create app window in screen of screen
        app_width = 818
        app_height = 766
        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        x_offset = int((screen_width - app_width) / 2) if screen_width > app_width else 0
        y_offset = int((screen_height - app_height) / 2) if screen_height > app_height else 0
        self.root.title(APP_TITLE)#("DensHit Reloaded")
        self.root.geometry("{}x{}+{}+{}".format(app_width, app_height, x_offset, y_offset))
        self._create_labels()
        self._reset()
        self.is_reset = True
        self.frames_total = 1   # avoid 0 as frame number
        self.be_traffic_active = False

        # Start app
        self.root.after(STATS_UPDATE, self._update_stats)
        self.root.mainloop()
        # Deactivate events and disconnect hostmods (IO Bridge, NCM, and MemoryAccess)
        self.gw.noc_bridge.deactivate()
        self.monitor.ctrl_mod.deactivate_monitoring()
        sleep(1)
        self.gw.noc_bridge.disconnect()
        assert(not self.gw.noc_bridge.is_connected())
        self.monitor.ctrl_mod.hm.disconnect()
        assert(not self.monitor.ctrl_mod.hm.is_connected())
        self.sys_manager.hm.disconnect()
        assert(not self.sys_manager.hm.is_connected())

    def _create_tile_tables(self):
        self._hcts = []
        self._lcts = []
        topology = "{}x{}".format(self.monitor.ctrl_mod.x_dim, self.monitor.ctrl_mod.y_dim)
        for tile in range(len(MAPPING[topology])):
            if MAPPING[topology][tile] == "HCT":
                self._hcts.append(tile)
            if MAPPING[topology][tile] == "LCT":
                self._lcts.append(tile)

    def _create_labels(self):
        # Position result frame
        self.result_frame = tk.Frame(self.root)
        self.result_frame.pack(anchor="n", side="right", padx=5, pady=5, fill=tk.Y)
        self.result = tk.Label(self.result_frame, image="")
        self.result.pack(anchor="n")
        optimsoc_frame = tk.Frame(self.result_frame)
        optimsoc_frame.pack(side="bottom")
        img = tk.PhotoImage(file="{}/{}.gif".format(IMG_DIR, LOGOS[2]))
        logo = tk.Label(optimsoc_frame, image=img)
        logo.img = img
        logo.pack(anchor="s", side="bottom")
        # Position image frame
        self.img_frame = tk.Frame(self.root)
        self.img_frame.pack(anchor="n", side="right", pady=5)
        self.img = tk.Label(self.img_frame, image="")
        self.img.pack(anchor="n")
        # Position info frame
        self.info_frame = tk.Frame(self.root, bd=0, highlightbackground="#bcbcbc", highlightcolor="#bcbcbc", highlightthickness=1, padx=1, pady=1)
        self.info_frame.pack(anchor="nw", padx=6, pady=6, fill=tk.X)
        tk.Label(self.info_frame, justify="left", text="Frames processed:").pack(anchor="w")
        self.processed_label = tk.Label(self.info_frame, justify="left", text="")
        self.processed_label.pack(anchor="w")
        self.core_label = []
        for i in range(len(self._hcts)):
            tk.Label(self.info_frame, justify="left", text="Core {} (Tile {}):".format(i, self._hcts[i])).pack(anchor="w")
            self.core_label.append(tk.Label(self.info_frame, justify="left", text=""))
            self.core_label[-1].pack(anchor="w")
        tk.Label(self.info_frame, justify="left", text="Frames per second:   ").pack(anchor="w")
        self.fps_label = tk.Label(self.info_frame, justify="left", text="")
        self.fps_label.pack(anchor="w")
        if SHOW_RATE:
            tk.Label(self.info_frame, justify="left", text="Detection Rate:").pack(anchor="w")
            self.rate_label = tk.Label(self.info_frame, justify="left", text="")
            self.rate_label.pack(anchor="w")
            tk.Label(self.info_frame, justify="left", text="False positive:").pack(anchor="w")
            self.false_pos_label = tk.Label(self.info_frame, justify="left", text="")
            self.false_pos_label.pack(anchor="w")
            tk.Label(self.info_frame, justify="left", text="False negative:").pack(anchor="w")
            self.false_neg_label = tk.Label(self.info_frame, justify="left", text="")
            self.false_neg_label.pack(anchor="w")
        # Position action frame
        self.action_frame = tk.Frame(self.root, bd=0, highlightbackground="#bcbcbc", highlightcolor="#bcbcbc", highlightthickness=1, padx=2, pady=2)
        self.action_frame.pack(anchor="n", padx=6, fill=tk.BOTH)
        self.train_button = tk.Button(self.action_frame, text='Start Training', command=self._button_train, state=tk.DISABLED)
        self.train_button.pack(anchor="w", fill=tk.X)
        self.run_button = tk.Button(self.action_frame, text='Run', command=self._button_run, state=tk.DISABLED)
        self.run_button.pack(anchor="w", fill=tk.X)
        self.stepping = tk.IntVar()
        self.checkbutton = tk.Checkbutton(self.action_frame, text="Single Step", variable=self.stepping, command=self._checkbox_action, state=tk.DISABLED)
        self.checkbutton.pack(anchor="w")
        self.step_button = tk.Button(self.action_frame, text='Step', command=self._button_step, state=tk.DISABLED)
        self.step_button.pack(anchor="w", fill=tk.X)
        self.reset_button = tk.Button(self.action_frame, text='Reset', command=self._reset, state=tk.DISABLED)
        self.reset_button.pack(anchor="w", fill=tk.X)
        # Position reset frame
        self.sys_reset_frame = tk.Frame(self.root, bd=0, highlightbackground="#bcbcbc", highlightcolor="#bcbcbc", highlightthickness=1, padx=2, pady=2)
        self.sys_reset_frame.pack(side="bottom", anchor="s", padx=6, pady=6, fill=tk.X)
        self.sys_reset_button = tk.Button(self.sys_reset_frame, text='Start System', command=self._sys_rst)
        self.sys_reset_button.pack(anchor="s", fill=tk.X)
        self.sys_program_button = tk.Button(self.sys_reset_frame, text='Program Cores', command=self._load_program)
        self.sys_program_button.pack(anchor="w", fill=tk.X)
        # Position BE traffic frame
        self.be_frame = tk.Frame(self.root, bd=0, highlightbackground="#bcbcbc", highlightcolor="#bcbcbc", highlightthickness=1, padx=2, pady=2)
        self.be_frame.pack(side="bottom", anchor="s", padx=6, fill=tk.X)
        self.be_button = tk.Button(self.be_frame, text='Start BE Traffic', command=self._toggle_be_traffic, state=tk.DISABLED)
        self.be_button.pack(anchor="w", fill=tk.BOTH)

    def _reset(self):
        self.running = False
        self.training = False
        self.send_next = False
        self.cores = []
        self.receive_buffer = []
        self.step_q = []
        for _ in range(len(self._hcts)):
            self.cores.append(None)
            self.receive_buffer.append([])
        self.cores_busy = 0
        self.processed = 0
        self.processed_old = 0
        self.processed_label.config(text="0")
        self.fps_label.config(text="0")
        self.fps_hist = []
        fps_hist_len = 1000 // STATS_UPDATE if STATS_UPDATE < 1000 else 1
        for _ in range(fps_hist_len):
            self.fps_hist.append(0)
        self.cores_processed = []
        for i in range(len(self._hcts)):
            self.cores_processed.append(0)
            self.core_label[i].config(text="0")
        if SHOW_RATE:
            self.errors = 0
            self.false_pos = 0
            self.false_neg = 0
            self.rate_label.config(text="-")
            self.false_pos_label.config(text="-")
            self.false_neg_label.config(text="-")
        self.run_button.config(text="Run")
        self.stepping.set(0)
        self.step_button.config(state=tk.DISABLED)
        img = tk.PhotoImage(file="{}/{}.gif".format(IMG_DIR, LOGOS[0]))
        self.img.config(image=img)
        self.img.image = img
        img = tk.PhotoImage(file="{}/{}.gif".format(IMG_DIR, LOGOS[1]))
        self.result.config(image=img)
        self.result.image = img

    def _sys_rst(self):
        if not self.is_reset:
            # Reset system
            self.monitor.reset()
            self._reset()
            self.run_button.config(state=tk.DISABLED)
            self.checkbutton.config(state=tk.DISABLED)
            self.reset_button.config(state=tk.DISABLED)
            self.train_button.config(state=tk.DISABLED)
            self.train_button.config(text='Start Training')
            self.be_button.config(text="Start BE Traffic", state=tk.DISABLED)
            self.be_traffic_active = False
            try:
                self.sys_manager.reset_system()
                self.sys_reset_button.config(text="Start System")
                self.sys_program_button.config(state=tk.NORMAL)
                self.is_reset = True
            except Exception:
                print("Error when resetting!")
        else:
            # Start system
            if self.monitor.configure_basic_demo_paths():
                self.gw.noc_bridge.activate()
                self.sys_manager.start_cpus()
                # Give cores time to start. Wait longer when simulating
                if self.simulation:
                    sleep(10)
                else:
                    sleep(0.1)
                self.sys_reset_button.config(text="Reset System")
                self.sys_program_button.config(state=tk.DISABLED)
                self.train_button.config(state=tk.NORMAL)
                self.is_reset = False
                self.monitor.enable_sm()
                self.be_button.config(state=tk.NORMAL)

    def _load_program(self):
        self.sys_reset_button.config(state=tk.DISABLED)
        self.sys_program_button.config(state=tk.DISABLED)
        self.sys_manager.load_memories()
        self.sys_reset_button.config(state=tk.NORMAL)
        self.sys_program_button.config(state=tk.NORMAL)

    def _toggle_be_traffic(self):
        if self.be_traffic_active:
            self.be_traffic_active = False
            self.be_button.config(text="Start BE Traffic")
            self.monitor.disable_be()
        else:
            self.monitor.enable_be()
            self.be_button.config(text="Stop BE Traffic")
            self.be_traffic_active = True

    def _update_stats(self):
        # Update FPS
        frames = self.processed - self.processed_old
        self.fps_hist.pop(0)
        self.fps_hist.append(frames)
        avg_fps = sum(self.fps_hist)
        self.fps_label.config(text=avg_fps)
        self.processed_old = self.processed
        self.root.after(STATS_UPDATE, self._update_stats)
        if self.processed > 0 and SHOW_RATE:
            # Update error rates
            rate = (1 - self.errors / self.processed) * 100
            self.rate_label.config(text="{:.2f}%".format(rate))
            rate = (self.false_pos / self.processed) * 100
            self.false_pos_label.config(text="{:.2f}%".format(rate))
            rate = (self.false_neg / self.processed) * 100
            self.false_neg_label.config(text="{:.2f}%".format(rate))

    def _cleanup(self):
        """
        Removes old frames that were not responded to. A new frame will be sent
        to the affected core the next time 'run' runs.
        """
        if CLEANUP != 0:
            curr_time = time()
            cleaned = False
            for core in range(len(self.cores)):
                if self.cores[core] is not None:
                    if (curr_time - self.cores[core].sent) > (CLEANUP / 1000):
                        print("{}: Cleanup for core {}".format(MOD, core))
                        self.cores[core] = None
                        self.cores_busy -= 1
                        cleaned = True
            if self.running and not self.stepping.get() and cleaned:
                self._run()
            if self.running and self.cores_busy > 0:
                self.root.after(CLEANUP, self._cleanup)

    def _update_frame(self, frame):
        if self.running:
            # Display frame
            img_path = "{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[frame.type], frame.img_no)
            img = tk.PhotoImage(file=img_path).zoom(21, 21)
            self.img.config(image=img)
            self.img.image = img
            # Update processed and core
            self.processed += 1
            self.processed_label.config(text=self.processed)
            self.cores_processed[frame.core] += 1
            self.core_label[frame.core].config(text=self.cores_processed[frame.core])
            # Determine result
            if frame.type == frame.detected:
                result = frame.type   # POS or NEG depending on type
            else:
                result = FPOS if frame.type is NEG else FNEG
                if SHOW_RATE:
                    self.errors += 1
                    if result == FPOS:
                        self.false_pos += 1
                    else:
                        self.false_neg += 1
            # Update result visualization
            res_path = "{}/{}.gif".format(IMG_DIR, RESULT_IMG[result])
            res_img = tk.PhotoImage(file=res_path)
            self.result.config(image=res_img)
            self.result.image = res_img

    def _button_run(self):
        if self.running:
            self.run_button.config(text="Run")
            self.running = False
            # Cleanup cores
            for core in range(len(self.cores)):
                if self.cores[core] is not None:
                    self.cores[core] = None
                    self.cores_busy -= 1
            self.step_button.config(state=tk.DISABLED)
            self.reset_button.config(state=tk.NORMAL)
            self.sys_reset_button.config(state=tk.NORMAL)
        else:
            self.training = False
            self.run_button.config(text="Stop")
            self.running = True
            if self.stepping.get():
                self.step_button.config(state=tk.NORMAL)
            self.reset_button.config(state=tk.DISABLED)
            self.sys_reset_button.config(state=tk.DISABLED)
            self.root.after(1, self._run)

    def _button_step(self):
        if self.running and self.stepping.get():
            self.step_q.append(True)

    def _checkbox_action(self):
        if not self.stepping.get():
            self.step_button.config(state=tk.DISABLED)
            self.root.after(1, self._run)
        elif self.running:
            self.step_button.config(state=tk.NORMAL)

    def _button_train(self):
        dialog = TrainingDialog(self.root, title="Select Training Method", args={"max_samples": min(MAX_IMG)})
        if dialog.result is True:
            self.train_button.config(state=tk.DISABLED)
            self.train_button.config(text="Training")
            self.training = True
            self.nr_sample_images_sent = 1
            self.send_next = True
            self.train_time = time()
            self.train_method = dialog.method
            self.nr_train_images = dialog.samples
            if dialog.method == TRAIN_KNN:
                self.k = dialog.k
                self.root.after(1, self.train)
            elif dialog.method == TRAIN_SVM:
                self.C = dialog.C
                self.max_passes = dialog.passes
                self.root.after(1, self.train_svm)
            elif dialog.method == LOAD_SVM:
                self.b = dialog.b
                self.w = dialog.w
                self.root.after(1, self.train)
            else:
                print("{}: Invalid training method ({})!".format(MOD, self.train_method))

    def train_svm(self):
        # Load image data, size(X) = 2*nr_train_images x img_height*img_width
        X = []
        for i in random.sample(range(MAX_IMG[0]), self.nr_train_images):
            X.extend(readPGM("{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[0], i)))
        for i in random.sample(range(MAX_IMG[1]), self.nr_train_images):
            X.extend(readPGM("{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[1], i)))

        # 1 labels for ped, -1 labels for nonped
        Y = [1] * self.nr_train_images + [-1] * self.nr_train_images

        # Initialize SVM with training data X and labels Y
        svm = SVM(X, Y, IMG_HEIGHT, IMG_WIDTH)

        # Extract features from training data using Histogram of Oriented Gradients
        #t = time()
        svm.extractHOG(CELLSIZE, CELLS_PER_BLOCK, NO_BINS)
        #print("{}: Feature Extraction Time: {}".format(MOD, time()-t))

        # Train Support Vector Machine with features
        #t = time()
        svm.trainSVM(self.C, self.max_passes)
        #print("{}: SVM Training Time: {}".format(MOD, time()-t))
        self.b = svm.b
        self.w = svm.w

        # Save w,b to file
        if not os.path.exists(SVM_DIR):
            os.mkdir(SVM_DIR)
        filestr = SVM_DIR + "/{}samples_{}passes_{}".format(self.nr_train_images, self.max_passes, datetime.now().strftime("%Y-%m-%d_%H:%M:%S"))
        with open(filestr, 'wb') as f:
            pickle.dump((self.w, self.b), f)

        self.root.after(1, self.train)

    def train(self):
        if self.training:
            if self.send_next:
                self.send_next = False
                data = self.get_data()
                for i in range(len(self._hcts)):
                    self.cores[i] = self.nr_sample_images_sent
                self.send_to_all_cores(data)

            if not self.nr_sample_images_sent in self.cores and self.train_method == TRAIN_KNN:
                self.nr_sample_images_sent = 1 if self.nr_sample_images_sent == 2 ** 32 - 1 else self.nr_sample_images_sent + 1
                self.send_next = True

            # Finished after sending infoframe + sample images for KNN or only sending infoframe for SVM
            if (((self.train_method == TRAIN_KNN and (self.nr_sample_images_sent > self.nr_train_images * 2)) or
                 not self.train_method == TRAIN_KNN) and
                 not self.cores_busy > 0):
                print("{}: Finished Training. Total Training Time was: {}s".format(MOD, time() - self.train_time))
                self.training = False
                self.train_button.config(state=tk.DISABLED, text="Training Finished")
                self.run_button.config(state=tk.NORMAL)
                self.checkbutton.config(state=tk.NORMAL)
                self.reset_button.config(state=tk.NORMAL)

        if (self.training or self.cores_busy > 0):
            self.root.after(10, self.train)

    def send_to_all_cores(self, data):
        payload = [0x00, 0xc5]
        payload.extend(list(self.nr_sample_images_sent.to_bytes(4, byteorder="little")))
        # Avoid 0xc500 in data
        data = [0xc4 if i == 0xc5 else i for i in data]
        payload.extend(data)
        for c in range(len(self.cores)):
            self.cores_busy += 1
            self.gw.send_data_tdm(c, payload, 8)

    def _run(self):
        if self.running:
            # Handle receives and do possible cleanup
            curr_time = time()
            for c in range(len(self.cores)):
                if self.cores[c] is not None:
                    # If detected field has been set it means the frame was received
                    if self.cores[c].detected is not None:
                        self.cores[c] = None
                        self.cores_busy -= 1
                    # Otherwise, check if timeout has been exceeded
                    else:
                        if CLEANUP != 0 and (curr_time - self.cores[c].sent) > (CLEANUP / 1000):
                            print("{}: Cleanup for core {}".format(MOD, c))
                            self.cores[c] = None
                            self.cores_busy -= 1
            while (self.cores_busy < len(self._hcts) and
                   (self.stepping.get() and len(self.step_q) > 0 or
                   not self.stepping.get())):
                # Send frames to cores
                self._send_frame()
                if len(self.step_q) > 0:
                    self.step_q.pop(0)
        if self.running or self.cores_busy > 0:
            self.root.after(10, self._run)

    def _send_frame(self):
        """
        Assign frame to core and send out the frame.
        """
        try:
            core_idx = self.cores.index(None)
            f = Frame()
            f.type = random.randint(0, 1)
            f.img_no = random.randint(0, MAX_IMG[f.type])
            f.frame_no = self.frames_total
            f.core = core_idx
            self.cores[core_idx] = f
            self._send_frame_to_core(core_idx)
            self.cores_busy += 1
            self.frames_total = 1 if self.frames_total == 2 ** 32 - 1 else self.frames_total + 1
        except ValueError as e:
            # Value errors can happen due to callback receive. Should not be an issue.
            print(e)
            print("{}: Cores list: {}, cores busy: {}".format(MOD, self.cores, self.cores_busy))
            pass

    def _send_frame_to_core(self, core_idx):
        """
        Send frame to a single core.
        """
        frame = self.cores[core_idx]
        img_path = "{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[frame.type], frame.img_no)

        # A new frame is indicated by '0x0' and '0xc5' as the first two payload
        # words.
        payload = [0x0, 0xc5]
        # The next 4 bytes determine the frame number
        payload.extend(list(self.cores[core_idx].frame_no.to_bytes(4, byteorder="little")))
        # The rest is the actual payload/frame
        data = readPGM(img_path)
        # Avoid 0xc500 in the payload
        data = [0xc4 if i == 0xc5 else i for i in data]
        payload.extend(data)
        #print("{}: Send payload (len: {}) to core {}: {}".format(MOD, len(payload), core_idx, [hex(i) for i in payload]))
        self.gw.send_data_tdm(core_idx, payload, 8)

    def _rcvd_response(self, core_idx):
        # Only proceed if the core is still expecting a frame
        if self.running and self.cores[core_idx] is not None:
            # Only proceed if the frame number matches the expected one.
            # If not it means a cleaned packet arrived late and the expected
            # packet is still in transmission.
            if self.receive_buffer[core_idx][0] == self.cores[core_idx].frame_no:
                self.cores[core_idx].detected = self.receive_buffer[core_idx][1]
                self._update_frame(self.cores[core_idx])
            else:
                print("{}: Received old frame number for core {}: {}".format(MOD, core_idx, self.receive_buffer[core_idx][0]))

        if self.training:
            # Check for correct response from core
            if self.receive_buffer[core_idx][1] == 0xc4 or self.receive_buffer[core_idx][1] == 0xc5:
                self.cores[core_idx] = None
                self.cores_busy -= 1
            else:
                print("{}: Received invalid response while training: {}".format(MOD, self.receive_buffer[core_idx][1]))

    def receive(self, type, ep, payload, src=None):
        if type == BE:
            # Currently not supported
            #print("{}: Received BE type packet from ep {}:\n{}".format(MOD, ep, [hex(p) for p in payload]))
            pass
        else:
            #print("{}: Received TDM response from core {} (tile {}): {}".format(MOD, ep, self._hcts[ep], [hex(x) for x in payload]))
            for word in payload:
                self.receive_buffer[ep].append(word)
            while len(self.receive_buffer[ep]) >= 2:
                self._rcvd_response(ep)
                self.receive_buffer[ep] = self.receive_buffer[ep][2:]

    def get_data(self):
        if self.train_method == TRAIN_SVM or self.train_method == LOAD_SVM:
            # Scale w and b to uint8 for transmission
            w, minw, maxw, b_low, b_high = self.scale_w_b(self.w, self.b)

            # Assemble SVM infoframe
            data = [0]                      # 0:     Classification method (KNN:1 SVM:0)
            data.append(0)                  # 1,2:   Not used with SVM
            data.append(0)
            data.append(NO_FEAT // 256)     # 3,4:   Number of features per image
            data.append(NO_FEAT % 256)
            data.append(0)                  # 5:     Not used with SVM
            data.append(b_high)             # 6,7:   SVM b
            data.append(b_low)
            data.append(minw)               # 8:     Smallest value in w
            data.append(maxw)               # 9:     Largest value in w
            data.append(CELLSIZE)           # 10+:   HOG parameters
            data.append(CELLS_PER_BLOCK)
            data.append(NO_BINS)
            data.append(IMG_HEIGHT)         # 13,14: Image height and width
            data.append(IMG_WIDTH)
            data.extend(w)                  # 15+:   SVM w

        else: # self.train_method == 'TRAIN_KNN
            assert(self.nr_sample_images_sent <= 2 * self.nr_train_images)

            if self.nr_sample_images_sent == 0:
                # Assemble knn infoframe
                data = [1]                                      # 0:     Classification method (KNN:1 SVM:0)
                data.append((self.nr_train_images >> 8) & 0xff) # 1,2:   Number of sample images that will be sent
                data.append(self.nr_train_images & 0xff)
                data.append((NO_FEAT >> 8) & 0xff)              # 3,4:   Number of features per image
                data.append(NO_FEAT & 0xff)
                data.append(self.k)                             # 5:     KNN parameter k
                data.append(0)                                  # 6+:    Not used with KNN
                data.append(0)
                data.append(0)
                data.append(0)
                data.append(CELLSIZE)                           # 10+:   HOG parameters
                data.append(CELLS_PER_BLOCK)
                data.append(NO_BINS)
                data.append(IMG_HEIGHT)                         # 13,14: Image height and width
                data.append(IMG_WIDTH)

            # ped images
            elif self.nr_sample_images_sent <= self.nr_train_images:
                img_path = "{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[0], random.randint(0, MAX_IMG[0]))
                data = readPGM(img_path)
            # non-ped images
            else:
                img_path = "{}/DC_ped_dataset_base/1/{:}/img_{:05d}.pgm".format(IMG_DIR, PED_IMG_DIR[1], random.randint(0, MAX_IMG[1]))
                data = readPGM(img_path)

        return data

    def scale_w_b(self, w, b):
        """
        Scale svm data in range -1...1 to uint8 for transmission.
        TODO: should be changed eventually to transmit floats.
        """
        minw = min(w)
        maxw = max(w)
        # encode w between -1...+1
        w = [ round((i - minw) * 255 / (maxw - minw))    for i in w]

        # encode min(w) and max(w)
        minw = round((minw + 1) * 255 / 2)
        maxw = round((maxw + 1) * 255 / 2)

        # Ensure values are inside of boundaries
        minw = minw if minw >= 0 and minw < 256 else 0 if minw < 0 else 255
        maxw = maxw if maxw >= 0 and maxw < 256 else 0 if maxw < 0 else 255

        # encode b values between -127...+127
        if b > 127 or b < -127:
            print("b out of range")

        b = round((b + 127) * 255)

        b_high = (b >> 8) & 0xff
        b_low = b & 0xff

        return w, minw, maxw, b_low, b_high

def stepPGM(f):
    while 1:
        data1 = f.read(1)
        if not data1[0] == ' ' and not data1[0] == '\n':
            break

    while 1:
        data2 = f.read(1)
        if not data2[0] == ord(' ') and not data2[0] == ord('\n'):
            data1 += data2
        else:
            break

    return int(data1)

def readPGM(filename):
    with open(filename, 'rb') as f:
        data = f.read(2)
        assert(data[0] == ord('P') and data[1] == ord('5'))

        height = stepPGM(f)
        width = stepPGM(f)
        maxvalue = stepPGM(f)
        data = f.read(height * width)
        data = [i for i in data]
        return data
