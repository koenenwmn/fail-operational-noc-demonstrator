/* Copyright (c) 2019-2022 by the author(s)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * =============================================================================
 *
 * Pedestrian detection application.
 * The application will wait for frames with image data to be sent by the host
 * PC. Once a frame has been received features will be extracted from the image
 * data, followed by a classification of the image as 'pedestrian' or
 * 'non-pedestrian'. The classification result will then be sent back to the
 * host PC.
 *
 * TODO: reduce float operations
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Simon Webhofer
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <or1k-support.h>
#include <optimsoc-baremetal.h>
#include "../lib_hybrid_mp_simple/hybrid_mp_simple_tdm.h"
#include "../lib_hybrid_mp_simple/hybrid_mp_simple_ps.h"

//#define DEBUG

// Current max. values hard-coded
#define MAX_FRAMESIZE 700
#define MAX_SAMPLES 400
#define MAX_FEAT 360
#define MAX_HISTOGRAMS 200

uint8_t volatile _frame[MAX_FRAMESIZE];
uint32_t volatile _frameno;
uint8_t volatile _frame_arrived;
uint8_t _infoframe_processed;

// Parameters
int _no_sample_images; // half of them ped, half non-ped
int _no_feat;
int _img_width;
int _cellsize;
int _cells_per_block;
int _no_bins;
int _no_cells_h;
int _no_cells_v;
int _no_blocks_h;
int _no_blocks_v;
int _bins_per_block;

// KNN
float _sample_images[MAX_SAMPLES * MAX_FEAT];
float _distances[MAX_SAMPLES];
int _indices[MAX_SAMPLES];
int _knn_k;

// SVM
float _svm_w[MAX_FEAT];

// HOG
#define PI 3.14159
#define EPSILON 0.1

float _features[MAX_FEAT];
float _histograms[MAX_HISTOGRAMS];


// HOG feature extraction
void extractHOG() {
#ifdef DEBUG
    printf("\nextractHOG\n");
#endif

    // For all blocks
    for (int bi = 0; bi < _no_blocks_v; bi++) {
        for (int bj = 0; bj < _no_blocks_h; bj++) {/*printf("Hog Block nr.%d",bi*_no_blocks_h+bj);*/
            // For all cells in block
            for (int ci = 0; ci < _cells_per_block; ci++) {
                for (int cj = 0; cj < _cells_per_block; cj++) {
                    // For all pixels in cell
                    for (int i = 1; i < _cellsize - 1; i++) {
                        for (int j = 1; j < _cellsize - 1; j++) {
                            // Calculate gradient angle and magnitude
                            int img_offset = bi * _cellsize * _img_width + bj * _cellsize + ci * _cellsize * _img_width + cj * _cellsize + i * _img_width + j;
                            int bin_offset = ((bi * _no_blocks_h + bj) * (_cells_per_block * _cells_per_block) + (ci * _cells_per_block + cj)) * _no_bins;

                            int hdiff = _frame[img_offset - 1] - _frame[img_offset + 1];
                            int vdiff = _frame[img_offset - 1 * _img_width] - _frame[img_offset + 1 * _img_width];

                            float angle = (atan((float)hdiff / vdiff) * 180 / PI) + 90;
                            float magnitude = sqrt((float)(hdiff * hdiff + vdiff * vdiff));
#ifdef DEBUG
                            printf("angle: %lf, magnitude: %lf\n", angle, magnitude);
#endif
                            // Add magnitude to the angles bin
                            if (angle <= 0 || angle > 180) {
                                _features[bin_offset] += magnitude / 2;
                                _features[bin_offset + _no_bins - 1] += magnitude / 2;
                            }
                            else {
                                for (int bin = 0; bin < _no_bins; bin++) {
                                    if (bin * 180 / _no_bins < angle && angle <= (bin + 1) * 180 / _no_bins) {
                                        float percentage = (angle - bin * 180 / _no_bins) / (180 / _no_bins);
#ifdef DEBUG
                                        printf("bin: %d, percentage: %lf\n", bin, percentage);
#endif
                                        _features[bin_offset + bin] += (1 - percentage) * magnitude;

                                        if (bin != _no_bins - 1) {
                                            _features[bin_offset + bin + 1] += percentage * magnitude;
                                        }
                                        else {
                                            _features[bin_offset] += percentage * magnitude;
                                        }
                                    }
                                }
                            }
#ifdef DEBUG
                            printf("offset: %d\n", bin_offset);
                            for (int l = 0; l < _no_bins; l++)
                                printf(" _features[offset+%d]: %lf\n", l, _features[bin_offset+l]);
#endif
                        }
                    }
                }
            }
        }
    }

    // Normalize histograms within each block
#ifdef DEBUG
    printf("\nNormalize Features:\n");
    for (int i = 0; i < _no_feat; i++)
        printf("%d: %lf\n", i, _features[i]);
#endif
    for (int bl = 0; bl < _no_blocks_h * _no_blocks_v; bl++) {
        float div = 0;
        for (int i = 0; i < _bins_per_block; i++) {
#ifdef DEBUG
            printf("%d: %lf\n", bl * _bins_per_block + i, _features[bl * _bins_per_block + i]);
#endif
            div += _features[bl * _bins_per_block + i] * _features[bl * _bins_per_block + i];
        }

        div = sqrt(div + EPSILON * EPSILON);

        for (int i = 0; i < _bins_per_block; i++) {
            _features[bl * _bins_per_block + i] /= div;
        }
    }
#ifdef DEBUG
    printf("HOG finished\n");
#endif
}

// Faster implementation of HOG
void extractHOG2() {
#ifdef DEBUG
    printf("\nextractHOG2\n");
#endif

    memset(_histograms, 0, MAX_HISTOGRAMS * sizeof(float));

    // For all cells
    for (int ci = 0; ci < _no_cells_v; ci++) {
        for (int cj = 0; cj < _no_cells_h; cj++) {
            // For all pixels in cell
            for (int i = 1; i < _cellsize - 1; i++) {
                for (int j = 1; j < _cellsize - 1; j++) {
                    // Calculate gradient angle and magnitude
                    int img_offset = (ci * _img_width + cj) * _cellsize + i * _img_width + j;
                    int bin_offset = (ci * _no_cells_h + cj) * _no_bins;

                    int hdiff = _frame[img_offset - 1] - _frame[img_offset + 1];
                    int vdiff = _frame[img_offset - 1 * _img_width] - _frame[img_offset + 1 * _img_width];

                    float angle = atan((float)hdiff / vdiff) * 180 / PI + 90;
                    float magnitude = sqrt((float)(hdiff * hdiff + vdiff * vdiff));
#ifdef DEBUG
                    printf("angle: %lf, magnitude: %lf\n", angle, magnitude);
#endif
                    // To satisfy the numerics god
                    if (angle <= 0 || angle > 180) {
                        _histograms[bin_offset] = magnitude / 2;
                        _histograms[bin_offset + _no_bins - 1] = magnitude / 2;
                    }
                    // Add magnitude to the angles bin
                    else {
                        for (int bin = 0; bin < _no_bins; bin++) {
                            if (bin * 180 / _no_bins < angle && angle <= (bin + 1) * 180 / _no_bins) {
                                float percentage = (angle - bin * 180 / _no_bins) / (180 / _no_bins);
                                _histograms[bin_offset + bin] += (1 - percentage) * magnitude;

                                if (bin != _no_bins - 1) {
                                    _histograms[bin_offset + bin + 1] += percentage * magnitude;
                                }
                                else {
                                    _histograms[bin_offset] += percentage * magnitude;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // For all blocks
    for (int bi = 0; bi < _no_blocks_v; bi++) {
        for (int bj = 0; bj < _no_blocks_h; bj++) {
            // Map the cells belonging to each block from _histograms[no_cells*_no_bins] to _features[_no_feat]
            for (int ci = 0; ci < _cells_per_block; ci++) {
                for (int cj = 0; cj < _cells_per_block; cj++) {
                    int index_f = ((bi * _no_blocks_h + bj) * _cells_per_block * _cells_per_block + ci * _cells_per_block + cj) * _no_bins;
                    int index_h = (bi * _no_cells_h + bj + _no_cells_h * ci + cj) * _no_bins;

                    memcpy(_features + index_f, _histograms + index_h, _no_bins * sizeof(float));
#ifdef DEBUG
                    printf("bi/bj: %d/%d, ci/cj: %d/%d\n", bi, bj, ci, cj);
                    printf("feat: %d, hist: %d, blocknr: %d, cellnr: %d\n", index_f, index_h, index_f/_no_bins, index_h/_no_bins);
#endif
                }
            }
        }
    }

    for (int bl = 0; bl < _no_blocks_h * _no_blocks_v; bl++) {
        float div = 0;
        for (int i = 0; i < _bins_per_block; i++) {
#ifdef DEBUG
            printf("%d: %f\n", bl * _bins_per_block + i, _histograms[bl * _bins_per_block + i]);
#endif
            div += _features[bl * _bins_per_block + i] * _features[bl * _bins_per_block + i];
        }
        div = sqrt(div + EPSILON * EPSILON);
        for (int i = 0; i < _bins_per_block; i++) {
            _features[bl * _bins_per_block + i] /= div;
        }
    }
#ifdef DEBUG
    printf("HOG2 finished\n");
#endif
}

void normL2() {
    for (int i = 0; i < _no_sample_images; i++) {
        for (int j = 0; j < _no_feat; j++) {
            _distances[i] += (_sample_images[_no_feat * i + j] - _features[j]) * (_sample_images[_no_feat * i + j] - _features[j]);
        }
    }
}

// Returns _indices of k smallest values in _distances[] as upper k values of _indices[]
void bubblesort() {
    for (int i = 0; i < _no_sample_images; i++) {
        _indices[i] = i;
    }

    for (int i = 0; i < _knn_k; i++) {
        for (int j = 0; j < _no_sample_images - 1; j++) {
            if (_distances[j] < _distances[j + 1]) {
                // Swap both array values and corresponding _indices
                float tmp_d = _distances[j];
                _distances[j] = _distances[j + 1];
                _distances[j + 1] = tmp_d;

                int tmp_i = _indices[j];
                _indices[j] = _indices[j + 1];
                _indices[j + 1] = tmp_i;
            }
        }
    }
}

// k-nearest neighbors classification
// Sample_images: row-major (2*_no_sample_images x _no_feat) matrix
uint32_t knn() {
    for (int i = 0; i < _no_sample_images; i++) {
        _distances[i] = 0;
    }

    // Calculate ||sample_image - test_image|| for all sample images
    normL2();

    // Find k smallest _distances
    bubblesort();

    int ped = 0;
    int nonped = 0;

    for (int i = _no_sample_images - 1; i > _no_sample_images - 1 - _knn_k; i--) {
        if (_indices[i] < _no_sample_images / 2) {
            ped += 1;
        }
        else {
            nonped += 1;
        }
    }
#ifdef DEBUG
    printf("knn result: ped: %d, nonped: %d\n", ped, nonped);
#endif
    // Return '0' for ped and '1' for non-ped
    return (uint32_t)((ped > nonped) ? 0 : 1);
}

uint32_t svm(float svm_b) {
    float result = 0;

    for (int i = 0; i < _no_feat; i++) {
        result += _features[i] * _svm_w[i];
    }

    result += svm_b;

    // Check if f(x) = w*x+b > 0
    // Return '0' for ped and '1' for non-ped
    return (uint32_t)((result > 0) ? 0 : 1);
}

// Called every time a frame arrives: evaluate infoframe, store sample image or classify
uint32_t process_frame() {
    static int no_sample_images_received = 0;
    static int use_knn = 0;
    static float svm_b = 0;

#ifdef DEBUG
    printf("process_frame: infoframe_processed: %d, no_sample_images_received: %d\n", _infoframe_processed, no_sample_images_received);
#endif

    uint32_t reply = 0;

    if (_infoframe_processed) {
        // Extract Features from image
        //float *features = extractHOG();
        extractHOG2();

        // Still receiving KNN sample images
        if (use_knn && (no_sample_images_received < _no_sample_images)) {
            memcpy(_sample_images + _no_feat * no_sample_images_received, _features, _no_feat);
            no_sample_images_received++;
#ifdef DEBUG
            printf("Received sample %d of %d\n", no_sample_images_received, _no_sample_images);
#endif
            reply = 0xc5;
        }
        // Classify frame
        else {
#ifdef DEBUG
            printf("Classify image frameno %lu\n", _frameno);
#endif

            if (use_knn) {
                reply = knn();
            }
            else {
                reply = svm(svm_b);
            }
        }
    }
    // First frame received: infoframe
    else {
        // 0: knn/svm
        // 1+2: # sample images
        // 3+4: # features
        // 5: k for knn (if used)
        // 6+7: b for svm (if used)
        // 8+9: min/max w for svm (if used)
        // 10: cell size
        // 11: cells per block
        // 12: # bins
        use_knn             = _frame[0];
        _no_sample_images   = ((_frame[1] << 8) | _frame[2]) * 2;
        _no_feat            = (_frame[3] << 8) | _frame[4];

        _cellsize           = _frame[10];
        _cells_per_block    = _frame[11];
        _no_bins            = _frame[12];

        int img_height      = _frame[13];
        _img_width          = _frame[14];

        _no_cells_h         = _img_width / _cellsize;
        _no_cells_v         = img_height / _cellsize;

        int blocksize       = _cellsize * _cells_per_block;
        _no_blocks_h        = (_img_width / (blocksize / 2) - 1);
        _no_blocks_v        = (img_height / (blocksize / 2) - 1);
        _bins_per_block     = _no_bins * _cells_per_block * _cells_per_block;

#ifdef DEBUG
        printf("Infoframe arrived: knn: %d, # sample images: %d, # features: %d\n", use_knn, _no_sample_images, _no_feat);
#endif

        if (use_knn) {
            _knn_k = _frame[5];
            // Clear memory for KNN
            memset(_sample_images, 0, MAX_SAMPLES * MAX_FEAT * sizeof(float));
            memset(_distances, 0, MAX_SAMPLES * sizeof(float));
            memset(_indices, 0, MAX_SAMPLES * sizeof(int));
        }
        else {
            // Clear memory for SVM
            memset(_svm_w, 0, MAX_FEAT * sizeof(float));

            // Copy frame[15:_no_feat+15] to _svm_w , uint8 -> float
            for (int i = 0; i < _no_feat; i++) {
                _svm_w[i] = _frame[i + 15];
            }

            // Decode w
            float minw = (float)_frame[8] * 2 / 255 - 1;
            float maxw = (float)_frame[9] * 2 / 255 - 1;

            for (int i = 0; i < _no_feat; i++) {
                _svm_w[i] = _svm_w[i] * (maxw - minw) / 255 + minw;
#ifdef DEBUG
                printf("_svm_w[%d]: %f\n", i, _svm_w[i]);
#endif
            }

            // Decode b
            svm_b = (_frame[6] << 8) | _frame[7];
            svm_b = svm_b / 255 - 127;
#ifdef DEBUG
            printf("svm_b: %lf\n", svm_b);
#endif
        }
        _infoframe_processed = 1;
        reply = 0xc4;
    }

    return reply;
}

// This handler is called by the driver when receiving a TDM message
void recv(uint32_t *buffer, size_t len) {
    static int bytes = 0;
    static int framesize = 0;
    static int corrupt_frame = 0;
    static int head_received = 0;

#ifdef DEBUG
    printf("Received data: [%lx", buffer[0]);
    for (int i = 1; i < len; i++)
        printf(", %lx", buffer[i]);
    printf("]\n");
#endif

    for (int i = 0; i < len; i++) {
        // In this application 'c500' is never used in the payload and hence used as
        // indicator for the beginning of a new frame. This is necessary in case the
        // communication is cut of while a frame is in transmission.
        // For more general applications this must be treated differently or it must
        // be ensured this value is never used in the payload.
        if ((buffer[i] >> 16) == 0xc500) {
            if (bytes != 0) {
                printf("Recover after loss (bytes: %d)\n", bytes);
                bytes = 0;
            }
            head_received = 1;
            corrupt_frame = 0;
            _frameno = 0;
            framesize = (buffer[i] & 0xffff) - 10; // Substract 10 bytes for frame start (0xc500), framesize, and framenumber
#ifdef DEBUG
        printf("Expecting: %d bytes payload\n", framesize);
#endif
        }
        else if (corrupt_frame == 0) {
            if (head_received == 1) {
                if (_frameno != 0) {
                    for (int j = 0; j < 4; j++) {
                        _frame[bytes + j] = (buffer[i] >> j * 8) & 0xff;
                    }
                    bytes += 4;
                    if (bytes >= framesize) {
#ifdef DEBUG
                        printf("Frame received\n");
#endif
                        bytes = 0;
                        framesize = 0;
                        head_received = 0;
                        _frame_arrived = 1;
                        // Rest of buffer is discarded in this case. However, in
                        // this application there should not be a rest.
                        return;
                    }
                }
                else if (head_received == 1) {
                    _frameno = buffer[i];
                }
                else {
                    corrupt_frame = 1;
                }
            }
            else {
                corrupt_frame = 1;
            }
        }
    }

    if (corrupt_frame) {
        printf("Received corrupt frame: [%lx", buffer[0]);
        for (int i = 1; i < len; i++)
            printf(", %lx", buffer[i]);
        printf("]\n");
    }

}

int main() {
    if (optimsoc_get_relcoreid() != 0) {
        return 0;
    }

    // Determine tiles rank
    int rank = optimsoc_get_ctrank();
    int tile_id = optimsoc_get_tileid();

    // Initialize optimsoc library
    optimsoc_init(0);
    // Initialize TDM library
    hybrid_mp_simple_init_tdm();
    // Add handler to receive messages from TDM endpoint 0
    hybrid_mp_simple_addhandler_tdm(0, &recv);
    // Enable TDM endpoint 0
    hybrid_mp_simple_enable_tdm(0);

    // Activate interrupts
    or1k_interrupts_enable();

    uint32_t reply[2];
    _frame_arrived = 0;
    _frameno = 0;
    _infoframe_processed = 0;

    printf("Rank %d waiting for TDM messages. Tile ID: %d\n", rank, tile_id);

    while (1) {
        if (_frame_arrived) {
#ifdef DEBUG
            printf("Frame available\n");
#endif
            _frame_arrived = 0;

            reply[0] = _frameno;
            reply[1] = process_frame();

            // Send reply to host
#ifdef DEBUG
            printf("Responding: [0x%lx, 0x%lx]\n\n", reply[0], reply[1]);
#endif
            hybrid_mp_simple_send_tdm(0, 2, (uint32_t*)reply);
        }
    }
    return 0;
}
