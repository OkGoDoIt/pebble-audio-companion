#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>

#include "caccelerate_blas.h"

void cacc_sgemv_row_major(int m, int n, const float *a, int lda, const float *x, float *y) {
    cblas_sgemv(CblasRowMajor, CblasNoTrans, m, n, 1.0f, a, lda, x, 1, 0.0f, y, 1);
}

void cacc_sgemv_row_major_add(int m, int n, const float *a, int lda, const float *x, float *y) {
    cblas_sgemv(CblasRowMajor, CblasNoTrans, m, n, 1.0f, a, lda, x, 1, 1.0f, y, 1);
}

void cacc_sgemm_row_major_bt(
    int m, int n, int k, const float *a, int lda, const float *b, int ldb, float *c, int ldc) {
    cblas_sgemm(
        CblasRowMajor, CblasNoTrans, CblasTrans, m, n, k, 1.0f, a, lda, b, ldb, 0.0f, c, ldc);
}
