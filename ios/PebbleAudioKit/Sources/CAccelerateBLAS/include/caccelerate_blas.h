#ifndef CACCELERATE_BLAS_H
#define CACCELERATE_BLAS_H

// One BLAS call for the vendored CoreAISpeech mel front end, compiled here in C with
// ACCELERATE_NEW_LAPACK defined. Calling `cblas_sgemv` straight from Swift goes through the
// legacy Accelerate header, which marks it deprecated (macOS 13.3 / iOS 16.4) and the kit
// builds warning-free by rule. The routine is the same one either way, so the numerics the
// parity test pins are unchanged.

/// y = A · x for a row-major `m × n` matrix `A` with leading dimension `lda` (≥ n), a length-`n`
/// vector `x`, and a length-`m` output `y`. Alpha 1, beta 0, unit strides.
void cacc_sgemv_row_major(int m, int n, const float *a, int lda, const float *x, float *y);

#endif
