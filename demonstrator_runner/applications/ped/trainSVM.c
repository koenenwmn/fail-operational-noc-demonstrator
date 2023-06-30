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
#include <time.h>
#include <math.h>

//#define DEBUG

#define maxi(x,y) ((x) >= (y)) ? (x) : (y)
#define mini(x,y) ((x) <= (y)) ? (x) : (y)

#define TOL 0.001
#define MIN_PROGRESS 0.00001

double vmult(double *a, double *b, int len) {
    double result = 0;
    for (int i = 0; i < len; i++) {
        result += a[i] * b[i];
    }

    return result;
}

double calc_E(double *a, double *x, int *y, int nr_train_images, int nr_feat, int index) {
    double result = 0;
    for (int i = 0; i < 2 * nr_train_images; i++) {
        result += a[i] * vmult(x + (i * nr_feat), x + (index * nr_feat), nr_feat) * y[i];
    }

    return result;
}

double* trainSVM(double *X, int *Y, int nr_feat, int nr_train_images, double C, int max_passes) {
#ifdef DEBUG
    printf("\nC: trainSVM\n");
#endif

    // Working Memory
    double *a = (double*)calloc(2 * nr_train_images, sizeof(double));
    double b = 0;

    // Random Seed
    srand(time(0));

    // Main Loop, terminate if no improvement after max_passes tries
    int passes = 0;
    while (passes < max_passes) {
#ifdef DEBUG
        printf("%d of %d passes\n", passes, max_passes);
#endif
        for (int i = 0; i < 2 * nr_train_images; i++) {
            // Calculate E_i
            double E_i = calc_E(a, X, Y, nr_train_images, nr_feat, i) + b - Y[i];

            // Check KKT
            if ((Y[i] * E_i < -TOL && a[i] < C) || (Y[i] * E_i > TOL && a[i] > 0)) {

                // Choose random j != i
                int j = 0;
                do {
                    j = rand() % (2 * nr_train_images);
                } while (j == i);

                // Calculate E_j
                double E_j = calc_E(a, X, Y, nr_train_images, nr_feat, j) + b
                        - Y[j];

                // Save old alphas
                double a_i_old = a[i];
                double a_j_old = a[j];

                // Calculate L and H
                double L = Y[i] != Y[j] ? maxi(0, a[j] - a[i]) : maxi(0, a[i] + a[j] - C);
                double H = Y[i] != Y[j] ? mini(C, C + a[j] - a[i]) : mini(C, a[i] + a[j]);

                if (L == H) {
                    continue;
                }

                // Calculate eta
                double eta = 2 * vmult(X + i * nr_feat, X + j * nr_feat, nr_feat)
                        - vmult(X + i * nr_feat, X + i * nr_feat, nr_feat)
                        - vmult(X + j * nr_feat, X + j * nr_feat, nr_feat);

                if (eta >= 0) {
                    continue;
                }

                // Compute new a_j
                a[j] = a[j] - Y[j] * (E_i - E_j) / eta;

                // Make sure new a_j stays between L and H
                a[j] = mini(a[j], H);
                a[j] = maxi(a[j], L);

                if (fabs(a[j] - a_j_old) < MIN_PROGRESS) {
                    continue;
                }

                // Calculate new a_i
                a[i] = a[i] + (a_j_old - a[j]) * Y[i] * Y[j];

                // Calculate b
                double b1 = b - E_i - Y[i] * (a[i] - a_i_old)
                        * vmult(X + i * nr_feat, X + i * nr_feat, nr_feat)
                        - Y[i] * (a[j] - a_j_old) * vmult(X + i * nr_feat, X + j * nr_feat, nr_feat);
                double b2 = b - E_j - Y[i] * (a[i] - a_i_old)
                        * vmult(X + i * nr_feat, X + j * nr_feat, nr_feat)
                        - Y[i] * (a[j] - a_j_old) * vmult(X + j * nr_feat, X + j * nr_feat, nr_feat);

                b = (b1 + b2) / 2;

                if (0 < a[i] && a[i] < C) {
                    b = b1;
                }

                if (0 < a[j] && a[j] < C) {
                    b = b2;
                }
            }
        }
        passes++;
    }

    // Calculate w
    double *w = (double*)calloc(nr_feat + 1, sizeof(double));

    for (int j = 0; j < nr_feat; j++) {
        for (int i = 0; i < 2 * nr_train_images; i++) {
            w[j] += a[i] * Y[i] * X[i * nr_feat + j];
        }
    }
    // Append b to w
    w[nr_feat] = b;
#ifdef DEBUG
    printf("\nC: trainSVM_END\n");
#endif
    return w;
}
