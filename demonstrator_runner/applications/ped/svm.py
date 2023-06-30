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

SVM implementation using a shared library implemented in C.

Author(s):
  Max Koenen <max.koenen@tum.de>
  Simon Webhofer

"""

from ctypes import *
import os

DLLPATH = os.environ['DEMONSTRATOR_DIR'] + "/demonstrator_runner/applications/ped/libSVM.so"

MOD = None

class SVM:
    """
    X : [nr_train_images x nr_]  training data matrix
    Y : label vector
    """

    def __init__(self, X, Y, height, width):
        MOD = self.__class__.__name__

        assert(len(X) > 1 and len(Y) * height * width == len(X))

        self.height = height
        self.width = width

        self.nr_train_images = len(X) // (height * width)

        # Normalize X in 0...1
        #X = [i/max(X) for i in X]

        self.X = X
        self.Y = Y

        #print("{}: SVM object created".format(MOD))

    def extractHOG(self, cellsize=6, cells_per_block=2, nr_bins=9):
        """
        Extract HOG features from every image in X
        """

        #print("{}: Extracting HOG Features")

        blocksize = cellsize * cells_per_block
        nr_blocks_h = (self.width // (blocksize // 2) - 1);
        nr_blocks_v = (self.height // (blocksize // 2) - 1);
        self.nr_feat = nr_bins * cells_per_block ** 2 * nr_blocks_h * nr_blocks_v;

        self.X_HOG = []
        for i in range(2 * self.nr_train_images):
            try:
                # i-th image data
                X = self.X[i * self.height * self.width:(i + 1) * self.height * self.width]
                # Call C function via Ctypes
                features = self._call_HOG_C(X, cellsize, cells_per_block, nr_bins)
            except Exception:
                print("{}: extractHOG failed at img nr. {}".format(MOD, i))

            # Save Features
            self.X_HOG.extend(features)

        #print("{}: HOG Features extracted successfully".format(MOD))

    def _call_HOG_C(self, X, cellsize, cells_per_block, nr_bins):
        """
        Extract HOG Features in C via Ctypes
        """

        # Load dll, compile with "gcc -shared -o libSVM.so -fPIC trainSVM.c extractHOG.c" first
        dll = CDLL(DLLPATH)

        # Specify argument types
        dll.extractHOG.argtypes = (POINTER(c_double), c_int, c_int, c_int, c_int, c_int)
        dll.extractHOG.restype = POINTER(c_double)

        # Memory for X
        array_X = c_double * (self.height * self.width)

        # Cast arguments to C data types
        arg_X = array_X(*X)
        arg_height = c_int(self.height)
        arg_width = c_int(self.width)
        arg_cellsize = c_int(cellsize)
        arg_cells_per_block = c_int(cells_per_block)
        arg_nr_bins = c_int(nr_bins)

        # Call C-function via ctypes
        result = dll.extractHOG(arg_X, arg_height, arg_width, arg_cellsize, arg_cells_per_block, arg_nr_bins)

        features = [result[i] for i in range(self.nr_feat)]

        return features

    def trainSVM(self, C=0.1, max_passes=20):
        """
        Trains SVM by calculating w and b from training data X and labels Y ; Test image x is class 1 if f(x)>0 , class -1 else, with f(x)=w*x+b
        See: http://cs229.stanford.edu/materials/smo.pdf
        """

        assert(C > 0 and max_passes > 0)

        #print("{}: Start training SVM".format(MOD))

        try:

            # Call C function via Ctypes
            w, b = self._call_SVM_C(C, max_passes)

        except Exception:
            print("{}: trainSVM failed!".format(MOD))

        # Save Results
        self.w = w
        self.b = b

        #print("{}: SVM trained successfully".format(MOD))
        #print("{}: w 1-20: {}".format(MOD, w[:20]))
        #print("{}: b: {}".format(MOD, b))
        return w, b

    def _call_SVM_C(self, C, max_passes):
        """
        Train SVM in C via Ctypes
        """

        # Load dll, compile with "gcc -shared -o libSVM.so -fPIC trainSVM.c extractHOG.c" first
        dll = CDLL(DLLPATH)

        # Specify argument types
        dll.trainSVM.argtypes = (POINTER(c_double), POINTER(c_int), c_int, c_int, c_double, c_int)
        dll.trainSVM.restype = POINTER(c_double)

        # Memory for X and Y
        array_X = c_double * (2 * self.nr_train_images * self.nr_feat)
        array_Y = c_int * (2 * self.nr_train_images)

        # Cast arguments to C data types
        arg_X = array_X(*self.X_HOG)
        arg_Y = array_Y(*self.Y)
        arg_nr_feat = c_int(self.nr_feat)
        arg_nr_train_im = c_int(self.nr_train_images)
        arg_C = c_double(C)
        arg_max_passes = c_int(max_passes)

        # Call C-function via ctypes
        result = dll.trainSVM(arg_X, arg_Y, arg_nr_feat, arg_nr_train_im, arg_C, arg_max_passes)

        w = [result[i] for i in range(self.nr_feat)]
        b = result[self.nr_feat]

        return w, b
