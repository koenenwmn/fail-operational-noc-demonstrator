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

Dialog box base class and dialog box to define training method for demonstrator.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

import tkinter as tk
from tkinter import filedialog
from tkinter import messagebox
import pickle
import os

SVM_DIR = os.environ['DEMONSTRATOR_DIR'] + "/demonstrator_runner/applications/ped/SVM_Data"

LOAD_SVM = 0
TRAIN_KNN = 1
TRAIN_SVM = 2

DEFAULT_NR_TRAIN_IMG = 50 # ped and non-ped each
DEFAULT_K = 7
DEFAULT_C = 0.1
DEFAULT_MAX_PASSES = 10
MAX_SAMPLES_KNN = 100

MOD = None


class BaseDialog(tk.Toplevel):
    """
    Base class for dialog boxes.
    """

    def __init__(self, parent, title=None, args={}):
        tk.Toplevel.__init__(self, parent)
        self.transient(parent)
        if title:
            self.title(title)
        self.parent = parent
        self.result = None
        self.args = args
        MOD = self.__class__.__name__

        body = tk.Frame(self)
        self.initial_focus = self.body(body)
        body.pack(padx=5, pady=5)

        self.buttonbox()
        self.grab_set()
        if not self.initial_focus:
            self.initial_focus = self

        self.protocol("WM_DELETE_WINDOW", self.cancel)
        # Find approx middle of screen
        x_offset = int((parent.winfo_screenwidth() / 2) - 130)
        y_offset = int((parent.winfo_screenheight() / 2) - 90)
        self.geometry("+{}+{}".format(x_offset, y_offset))

        self.initial_focus.focus_set()
        self.wait_window(self)

    def body(self, master):
        pass

    def buttonbox(self):
        # Add standard button box.
        box = tk.Frame(self)

        w = tk.Button(box, text="OK", width=10, command=self.ok, default=tk.ACTIVE)
        w.pack(side=tk.LEFT, padx=5, pady=5)
        w = tk.Button(box, text="Cancel", width=10, command=self.cancel)
        w.pack(side=tk.LEFT, padx=5, pady=5)

        self.bind("<Return>", self.ok)
        self.bind("<Escape>", self.cancel)

        box.pack()

    # Standard button semantics
    def ok(self, event=None):
        if not self.validate():
            # Put focus back
            self.initial_focus.focus_set()
            return

        self.withdraw()
        self.update_idletasks()

        self.apply()

        self.cancel()

    def cancel(self, event=None):
        # Put focus back to the parent window
        self.parent.focus_set()
        self.destroy()

    # Command hooks
    def validate(self):
        return 1 # override

    def apply(self):
        pass # override


class TrainingDialog(BaseDialog):
    def body(self, master):
        self.radiobox_frame = tk.Frame(master)
        self.radiobox_frame.pack(side="left", anchor="n", padx=6, pady=6, fill=tk.X)
        self.train_method_var = tk.IntVar()
        self.load_svm_radiobutton = tk.Radiobutton(self.radiobox_frame, text="Load SVM", variable=self.train_method_var, command=self.check_method, value=LOAD_SVM)
        self.load_svm_radiobutton.pack(anchor="w")
        self.load_svm_radiobutton.select()
        self.train_knn_radiobutton = tk.Radiobutton(self.radiobox_frame, text="Train KNN", variable=self.train_method_var, command=self.check_method, value=TRAIN_KNN)
        self.train_knn_radiobutton.pack(anchor="w")
        self.train_svm_radiobutton = tk.Radiobutton(self.radiobox_frame, text="Train SVM", variable=self.train_method_var, command=self.check_method, value=TRAIN_SVM)
        self.train_svm_radiobutton.pack(anchor="w")

        self.methods_frame = tk.Frame(master)
        self.methods_frame.pack(anchor="n", padx=6, pady=6, fill=tk.X)
        self.k_entry_frame = tk.Frame(self.methods_frame)
        self.k_entry_frame.pack(anchor="w", fill=tk.X)
        tk.Label(self.k_entry_frame, text="k:").pack(anchor="w", side=tk.LEFT)
        self.k_entry = tk.Entry(self.k_entry_frame, width=7, justify=tk.RIGHT)
        self.k_entry.pack(anchor="w", side=tk.RIGHT)
        self.k_entry.insert(0, str(DEFAULT_K))

        self.img_entry_frame = tk.Frame(self.methods_frame)
        self.img_entry_frame.pack(anchor="w", fill=tk.X)
        tk.Label(self.img_entry_frame, text="Frames:").pack(side=tk.LEFT)
        self.train_im_entry = tk.Entry(self.img_entry_frame, width=7, justify=tk.RIGHT)
        self.train_im_entry.pack(side=tk.RIGHT)
        self.train_im_entry.insert(0, str(DEFAULT_NR_TRAIN_IMG))

        self.c_entry_frame = tk.Frame(self.methods_frame)
        self.c_entry_frame.pack(anchor="w", fill=tk.X)
        tk.Label(self.c_entry_frame, text="C:").pack(side=tk.LEFT)
        self.c_entry = tk.Entry(self.c_entry_frame, width=7, justify=tk.RIGHT)
        self.c_entry.pack(side=tk.RIGHT)
        self.c_entry.insert(0, str(DEFAULT_C))

        self.passes_entry_frame = tk.Frame(self.methods_frame)
        self.passes_entry_frame.pack(anchor="w", fill=tk.X)
        tk.Label(self.passes_entry_frame, text="Passes:").pack(side=tk.LEFT)
        self.max_passes_entry = tk.Entry(self.passes_entry_frame, width=7, justify=tk.RIGHT)
        self.max_passes_entry.pack(side=tk.RIGHT)
        self.max_passes_entry.insert(0, str(DEFAULT_MAX_PASSES))

        self.check_method()

        return self.load_svm_radiobutton # initial focus

    def apply(self):
        success = True
        warnstr = ""
        errorstr = ""
        self.samples = DEFAULT_NR_TRAIN_IMG
        # Check if inputs are valid
        if self.method == TRAIN_KNN or self.method == TRAIN_SVM:
            try:
                self.samples = int(self.train_im_entry.get())
            except ValueError:
                warnstr += "Error reading number of samples!\nUsing default value ({}).\n\n".format(DEFAULT_NR_TRAIN_IMG)
                self.samples = DEFAULT_NR_TRAIN_IMG
            if self.samples < 0:
                warnstr += "Invalid number of sample images!\nUsing default value ({}).\n\n".format(DEFAULT_NR_TRAIN_IMG)
                self.samples = DEFAULT_NR_TRAIN_IMG
            elif self.samples > self.args["max_samples"]:
                warnstr += "Too many sample images.\nLimiting to {}.\n\n".format(self.args["max_samples"])
                self.samples = self.args["max_samples"]
        if self.method == TRAIN_KNN:
            try:
                self.k = int(self.k_entry.get())
            except ValueError:
                warnstr += "Error reading 'k'!\nUsing default value ({}).\n\n".format(DEFAULT_K)
                self.k = DEFAULT_K
            if self.k <= 0 or self.k > MAX_SAMPLES_KNN * 2 or self.k > self.samples * 2:
                newk = min([MAX_SAMPLES_KNN * 2, self.samples * 2])
                warnstr += "Too large value for 'k'.\nLimiting to {}.\n\n".format(newk)
                self.k = newk
        if self.method == TRAIN_SVM:
            self.svm_dir = SVM_DIR
            try:
                self.C = float(self.c_entry.get())
            except ValueError:
                warnstr += "Error reading 'C'!\nUsing default value ({}).\n\n".format(DEFAULT_C)
                self.C = DEFAULT_C
            if self.C <= 0:
                warnstr += "Invalid value for 'C'!\nUsing default value ({}).\n\n".format(DEFAULT_C)
                self.C = DEFAULT_C
            try:
                self.passes = int(self.max_passes_entry.get())
            except ValueError:
                warnstr += "Error reading number of passes!\nUsing default value ({}).\n\n".format(DEFAULT_MAX_PASSES)
                self.passes = DEFAULT_MAX_PASSES
            if self.passes <= 0:
                warnstr += "Invalid number of passes!\nUsing default value ({}).\n\n".format(DEFAULT_MAX_PASSES)
                self.passes = DEFAULT_MAX_PASSES
        if self.method == LOAD_SVM:
            # Check if SVM_DIR exists and is not empty
            if not os.path.exists(SVM_DIR) or not os.listdir(SVM_DIR):
                errorstr += "Could not find any SVM data at default location: {}\n\n".format(SVM_DIR)
                success = False
            else:
                # SVM data file will be selected here
                svm_file = tk.filedialog.askopenfilename(initialdir=SVM_DIR)
                # Dialog was closed without selection
                if not svm_file:
                    success = False
                else:
                    # Read data from selected file
                    with open(svm_file, 'rb') as f:
                        self.w, self.b = pickle.load(f)
                    #print("{}; pickle loaded: w: {}, b: {}".format(MOD, self.w, self.b))
        if self.method != TRAIN_KNN and self.method != TRAIN_SVM and self.method != LOAD_SVM:
            errorstr += "Invalid Method: '{}'!\n\n".format(self.method)
            success = False
        if warnstr != "":
            tk.messagebox.showwarning(message=warnstr)
        if errorstr != "":
            tk.messagebox.showerror(message=errorstr)
        self.result = success

    def check_method(self):
        self.method = self.train_method_var.get()
        if self.method == TRAIN_KNN:
            self.k_entry.config(state=tk.NORMAL)
            self.train_im_entry.config(state=tk.NORMAL)
            self.c_entry.config(state=tk.DISABLED)
            self.max_passes_entry.config(state=tk.DISABLED)
        elif self.method == TRAIN_SVM:
            self.k_entry.config(state=tk.DISABLED)
            self.train_im_entry.config(state=tk.NORMAL)
            self.c_entry.config(state=tk.NORMAL)
            self.max_passes_entry.config(state=tk.NORMAL)
        elif self.method == LOAD_SVM:
            self.k_entry.config(state=tk.DISABLED)
            self.train_im_entry.config(state=tk.DISABLED)
            self.c_entry.config(state=tk.DISABLED)
            self.max_passes_entry.config(state=tk.DISABLED)
        else:
            print("{}: Invalid method in 'check_method': {}".format(MOD, method))
