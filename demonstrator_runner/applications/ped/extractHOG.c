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
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Simon Webhofer
 */

#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <math.h>

//#define DEBUG

#define PI 3.14159
#define EPSILON 0.1

int blocksize;
int nr_cells;
int nr_blocks_h;
int nr_blocks_v;
int nr_feat;
int bins_per_block;

double* extractHOG(double *img, int height, int width, int cellsize, int cells_per_block, int nr_bins) {
#ifdef DEBUG
    printf("ctypes:extractHOG %d %d\n",height,width);
#endif

    blocksize = cellsize * cells_per_block;
    nr_cells = height * width / (cellsize * cellsize);
    nr_blocks_h = (width / (blocksize / 2) - 1);
    nr_blocks_v = (height / (blocksize / 2) - 1);
    nr_feat = nr_bins * cells_per_block * cells_per_block * nr_blocks_h * nr_blocks_v;
    bins_per_block = nr_bins * cells_per_block * cells_per_block;

    double *features = (double*)calloc(nr_feat, sizeof(double));
    if (features == NULL)
        printf("\n\n\nNo Memory for features\n\n\n");

    // For all blocks
    for (int bi = 0; bi < nr_blocks_v; bi++) {
        for (int bj = 0; bj < nr_blocks_h; bj++) {
            // For all cells in block
            for (int ci = 0; ci < cells_per_block; ci++) {
                for (int cj = 0; cj < cells_per_block; cj++) {
                    // For all pixels in cell
                    for (int i = 1; i < cellsize - 1; i++) {
                        for (int j = 1; j < cellsize - 1; j++) {
                            // Calculate gradient angle and magnitude
                            int img_offset = bi * cellsize * width + bj * cellsize + ci * cellsize * width + cj * cellsize + i * width + j;
                            int bin_offset = ((bi * nr_blocks_h + bj) * (cells_per_block * cells_per_block) + (ci * cells_per_block + cj)) * nr_bins;

                            double hdiff = img[img_offset - 1] - img[img_offset + 1];
                            double vdiff = img[img_offset - 1 * width] - img[img_offset + 1 * width];

                            double angle = (atan(hdiff / vdiff) * 180 / PI) + 90;
                            double magnitude = sqrt(hdiff * hdiff + vdiff * vdiff);
#ifdef DEBUG
                            printf("angle:%lf magnitude%lf\n", angle, magnitude);
#endif
                            // Add magnitude to the angles bin
                            if (angle <= 0 || angle > 180) {
                                features[bin_offset] = magnitude / 2;
                                features[bin_offset + nr_bins - 1] = magnitude / 2;
                            }
                            else {
                                for (int bin = 0; bin < nr_bins; bin++) {
                                    if (bin * 180 / nr_bins < angle && angle <= (bin + 1) * 180 / nr_bins) {
                                        double percentage = (angle - bin * 180 / nr_bins) / (180 / nr_bins);
#ifdef DEBUG
                                        printf("bin:%d\n", bin);
                                        printf("percentage:%lf\n", percentage);
#endif
                                        features[bin_offset + bin] += (1 - percentage) * magnitude;

                                        if (bin != nr_bins - 1) {
                                            features[bin_offset + bin + 1] += percentage * magnitude;
                                        }
                                        else {
                                            features[bin_offset] += percentage * magnitude;
                                        }
                                    }
                                }
                            }
#ifdef DEBUG
                            printf("offset:%d\n", bin_offset);
                            for (int l = 0; l < nr_bins; l++)
                                printf(" features%lf ", features[bin_offset+l]);
#endif
                        }
                    }
                }
            }
        }
    }

    // Normalize histograms within each block
#ifdef DEBUG
    printf("\nFeatures before Normalization:\n");
    for (int i = 0; i < nr_feat; i++)
        printf("%d:%lf \n", i, features[i]);
#endif

    for (int bl = 0; bl < nr_blocks_h * nr_blocks_v; bl++) {
        double div = 0;
        for (int i = 0; i < bins_per_block; i++) {
#ifdef DEBUG
            printf("%d: %lf\n", bl * bins_per_block + i,features[bl * bins_per_block + i]);
#endif
            div += features[bl * bins_per_block + i]
                    * features[bl * bins_per_block + i];
        }

        div = sqrt(div + EPSILON * EPSILON);
#ifdef DEBUG
        printf("%lf ", div);
#endif
        for (int i = 0; i < bins_per_block; i++) {
            features[bl * bins_per_block + i] /= div;
        }
    }
    return features;
}
