#ifndef ABPOA_SIMD_INTERNAL_H
#define ABPOA_SIMD_INTERNAL_H

#include "simd_instruction.h"

struct abpoa_simd_matrix_t {
    SIMDi *s_mem; uint64_t s_msize;
    int *dp_beg, *dp_end, *dp_beg_sn, *dp_end_sn, rang_m;
    // Each DP row keeps only its band, packed one row after another into s_mem (see simd_abpoa_new_row):
    // dp_row[i] is row i's H addressed by absolute block index, dp_row_w[i] the step from one of its matrices
    // to the next.
    SIMDi **dp_row; int64_t *dp_row_w;
};

#endif
