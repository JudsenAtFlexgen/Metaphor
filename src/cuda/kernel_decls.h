/* GENERATED FILE */

#include "kernel_header.h"

#if defined(__cplusplus)
    #define EXTERN_C extern "C"
#else
    #define EXTERN_C extern
#endif

EXTERN_C void launch_tanh_r16(
  StreamCtx stream,
  const r16* a,
        r16* b, 
  len_t N
);
EXTERN_C void launch_tanh_r32(
  StreamCtx stream,
  const r32* a,
        r32* b, 
  len_t N
);
EXTERN_C void launch_inner_product_ij_j_r16(
  StreamCtx stream,
  const r16 *A, 
  const r16 *x,
        r16 alpha, // scales product
        r16 *y,
        r16 beta, // blends C back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_inner_product_ij_j_r32(
  StreamCtx stream,
  const r32 *A, 
  const r32 *x,
        r32 alpha, // scales product
        r32 *y,
        r32 beta, // blends C back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_hadamard_reverse_r16(
  StreamCtx stream,
  r16 *grads_a,
  const r16 *value_b,
  const r16 *grads_c,
  len_t N
);
EXTERN_C void launch_hadamard_reverse_c16(
  StreamCtx stream,
  c16 *grads_a,
  const c16 *value_b,
  const c16 *grads_c,
  len_t N
);
EXTERN_C void launch_hadamard_reverse_r32(
  StreamCtx stream,
  r32 *grads_a,
  const r32 *value_b,
  const r32 *grads_c,
  len_t N
);
EXTERN_C void launch_hadamard_reverse_c32(
  StreamCtx stream,
  c32 *grads_a,
  const c32 *value_b,
  const c32 *grads_c,
  len_t N
);
EXTERN_C void launch_outer_product_i_j_r16(
  StreamCtx stream,
  const r16 *x,
  const r16 *y, 
        r16 alpha, // scales product
        r16 *A,
        r16 beta, // blends A back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_outer_product_i_j_r32(
  StreamCtx stream,
  const r32 *x,
  const r32 *y, 
        r32 alpha, // scales product
        r32 *A,
        r32 beta, // blends A back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_subtraction_r16(
  StreamCtx stream,
  const r16* a,
  const r16* b, 
  r16* c, 
  len_t N
);
EXTERN_C void launch_subtraction_c16(
  StreamCtx stream,
  const c16* a,
  const c16* b, 
  c16* c, 
  len_t N
);
EXTERN_C void launch_subtraction_r32(
  StreamCtx stream,
  const r32* a,
  const r32* b, 
  r32* c, 
  len_t N
);
EXTERN_C void launch_subtraction_c32(
  StreamCtx stream,
  const c32* a,
  const c32* b, 
  c32* c, 
  len_t N
);
EXTERN_C void launch_leaky_relu_r16(
  StreamCtx stream,
  const r16* a,
        r16* b, 
        r16 coef,
  len_t N
);
EXTERN_C void launch_leaky_relu_r32(
  StreamCtx stream,
  const r32* a,
        r32* b, 
        r32 coef,
  len_t N
);
EXTERN_C void launch_transpose_2D_r16(
    StreamCtx stream,
    const r16* src,
          r16* dst,
    r16 dst_coef,
    len_t row,
    len_t col
);
EXTERN_C void launch_transpose_2D_r32(
    StreamCtx stream,
    const r32* src,
          r32* dst,
    r32 dst_coef,
    len_t row,
    len_t col
);
EXTERN_C void launch_fill_r16(
  StreamCtx stream,
  r16* dev_a,
  r16 value, 
  len_t N
);
EXTERN_C void launch_fill_c16(
  StreamCtx stream,
  c16* dev_a,
  c16 value, 
  len_t N
);
EXTERN_C void launch_fill_r32(
  StreamCtx stream,
  r32* dev_a,
  r32 value, 
  len_t N
);
EXTERN_C void launch_fill_c32(
  StreamCtx stream,
  c32* dev_a,
  c32 value, 
  len_t N
);
EXTERN_C void launch_perumutate_r16(
  RTensor16 X, RTensor16 Y, Permutation P
);
EXTERN_C void launch_permutate_c16(
  CTensor16 X, CTensor16 Y, Permutation P
);
EXTERN_C void launch_perumutate_r32(
  RTensor32 X, RTensor32 Y, Permutation P
);
EXTERN_C void launch_permutate_c32(
  CTensor32 X, CTensor32 Y, Permutation P
);
EXTERN_C void launch_relu_leaky_reverse_r16(
  StreamCtx stream,
  const r16 *a_value,
        r16 *a_grads,
  const r16 *b_grads,
        r16 coef,
  len_t N
);
EXTERN_C void launch_relu_leaky_reverse_r32(
  StreamCtx stream,
  const r32 *a_value,
        r32 *a_grads,
  const r32 *b_grads,
        r32 coef,
  len_t N
);
EXTERN_C void launch_addition_r16(
  StreamCtx stream,
  const r16* a,
  const r16* b, 
  r16* c, 
  len_t N
);
EXTERN_C void launch_addition_c16(
  StreamCtx stream,
  const c16* a,
  const c16* b, 
  c16* c, 
  len_t N
);
EXTERN_C void launch_addition_r32(
  StreamCtx stream,
  const r32* a,
  const r32* b, 
  r32* c, 
  len_t N
);
EXTERN_C void launch_addition_c32(
  StreamCtx stream,
  const c32* a,
  const c32* b, 
  c32* c, 
  len_t N
);
EXTERN_C void launch_inner_product_i_ij_r16(
  StreamCtx stream,
  const r16 *x,
  const r16 *A, 
        r16 alpha, // scales product
        r16 *y,
        r16 beta, // blends y back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_inner_product_i_ij_r32(
  StreamCtx stream,
  const r32 *x,
  const r32 *A, 
        r32 alpha, // scales product
        r32 *y,
        r32 beta, // blends y back in
  len_t M, 
  len_t N
);
EXTERN_C void launch_addition_reverse_r16(
  StreamCtx stream,
  r16* a, 
  const r16* b, 
  len_t N
);
EXTERN_C void launch_addition_reverse_c16(
  StreamCtx stream,
  c16* a, 
  const c16* b, 
  len_t N
);
EXTERN_C void launch_addition_reverse_r32(
  StreamCtx stream,
  r32* a, 
  const r32* b, 
  len_t N
);
EXTERN_C void launch_addition_reverse_c32(
  StreamCtx stream,
  c32* a, 
  const c32* b, 
  len_t N
);
EXTERN_C void launch_matmul_2D_r16(
  StreamCtx stream,
  const r16 *A, 
  const r16 *B,
        r16 alpha, // scales product
        r16 *C,
        r16 beta, // blends C back in
  len_t M, 
  len_t N, 
  len_t K 
);
EXTERN_C void launch_matmul_2D_r32(
  StreamCtx stream,
  const r32 *A, 
  const r32 *B,
        r32 alpha, // scales product
        r32 *C,
        r32 beta, // blends C back in
  len_t M, 
  len_t N, 
  len_t K 
);
EXTERN_C void launch_sequence_r16(
  StreamCtx stream,
  r16* dev_a,
  r16 init,
  r16 step,
  len_t N
);
EXTERN_C void launch_sequence_r32(
  StreamCtx stream,
  r32* dev_a,
  r32 init,
  r32 step,
  len_t N
);
EXTERN_C void launch_subtraction_reverse_r16(
  StreamCtx stream,
  r16* a, 
  const r16* b, 
  const r16 coef,
  len_t N
);
EXTERN_C void launch_subtraction_reverse_c16(
  StreamCtx stream,
  c16* a, 
  const c16* b, 
  const r16 coef,
  len_t N
);
EXTERN_C void launch_subtraction_reverse_r32(
  StreamCtx stream,
  r32* a, 
  const r32* b, 
  const r32 coef,
  len_t N
);
EXTERN_C void launch_subtraction_reverse_c32(
  StreamCtx stream,
  c32* a, 
  const c32* b, 
  const r32 coef,
  len_t N
);
EXTERN_C void launch_tanh_reverse_r16(
  StreamCtx stream,
        r16 *a_grads,
  const r16 *b_value,
  const r16 *b_grads,
  len_t N
);
EXTERN_C void launch_tanh_reverse_r32(
  StreamCtx stream,
        r32 *a_grads,
  const r32 *b_value,
  const r32 *b_grads,
  len_t N
);
EXTERN_C void launch_hadamard_r16(
  StreamCtx stream,
  const r16* a,
  const r16* b, 
  r16* c, 
  len_t N
);
EXTERN_C void launch_hadamard_c16(
  StreamCtx stream,
  const c16* a,
  const c16* b, 
  c16* c, 
  len_t N
);
EXTERN_C void launch_hadamard_r32(
  StreamCtx stream,
  const r32* a,
  const r32* b, 
  r32* c, 
  len_t N
);
EXTERN_C void launch_hadamard_c32(
  StreamCtx stream,
  const c32* a,
  const c32* b, 
  c32* c, 
  len_t N
);