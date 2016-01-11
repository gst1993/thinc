# cython: profile=True
# cython: cdivision=True
# cython: infer_types=True
cimport cython
from libc.string cimport memcpy

from cymem.cymem cimport Pool
from preshed.maps cimport MapStruct as MapC
from preshed.maps cimport map_get as Map_get
from preshed.maps cimport map_set as Map_set

from .structs cimport IteratorC
from .structs cimport FeatureC
from .structs cimport ConstantsC

from .typedefs cimport len_t
from .typedefs cimport idx_t

from .blas cimport MatMat, MatVec, VecVec, Vec

from .structs cimport do_iter_t
from .structs cimport do_feed_fwd_t
from .structs cimport do_end_fwd_t
from .structs cimport do_begin_fwd_t
from .structs cimport do_begin_bwd_t
from .structs cimport do_end_bwd_t
from .structs cimport do_feed_bwd_t
from .structs cimport do_update_t


cdef extern from "math.h" nogil:
    float expf(float x)
    float sqrtf(float x)


DEF EPS = 0.000001 
DEF ALPHA = 1.0


cdef int advance_iterator(
    IteratorC* it,
        const len_t* widths,
            len_t nr_layer,
        int inc) nogil:
    it.nr_out = widths[it.i+1]
    it.nr_in = widths[it.i]
    it.W = 0
    cdef int i
    for i in range(it.i):
        it.W += widths[i+1] * widths[i]
        it.W += widths[i+1]
    it.bias = it.W + (it.nr_out * it.nr_in)
    it.gamma = 0
    it.beta = 0

    it.Ex = 0
    it.Vx = 0
    it.E_dXh = 0
    it.E_dXh_Xh = 0
    it.i += inc
    if nr_layer >= it.i and it.i >= 0:
        return True
    else:
        return False


cdef void dot_plus__ELU(
    float* output,
        const float* bias,
        len_t nr_out,
        const float* input_,
            len_t nr_in,
        const float* W
) nogil:
    dot_plus(output,
        bias, nr_out, input_, nr_in, W)
    ELU(output, nr_out)


cdef void dense_update(
    float* weights,
    float* momentum,
    float* gradient,
        len_t nr_weight,
        const float* const* bwd,
        const float* const* fwd,
        const len_t* widths,
            len_t nr_layer,
        const ConstantsC* hp,
        do_iter_t iterate,
        do_update_t do_update
) nogil:
    cdef IteratorC it
    it.i = 0
    while iterate(&it, widths, nr_layer, 1):
        MatMat.add_outer_i(&gradient[it.W], # Gradient of synapse weights
            bwd[it.i+1], fwd[it.i], it.nr_out, it.nr_in)
        VecVec.add_i(&gradient[it.bias], # Gradient of bias weights
            bwd[it.i+1], 1.0, it.nr_out)
    do_update(weights, momentum, gradient,
        nr_weight, hp)


cdef void dELU__dDot(
    float* dX,
    float* dY,
        len_t nr_wide,
        const float* Y,
        len_t nr_above,
        const float* W
) nogil:
    d_ELU(dY,
        Y, nr_above)
    d_dot(dX,
        nr_above, dY, nr_wide, W)


cdef void dot_plus(
    float* out,
        const float* bias,
            len_t nr_out,
        const float* in_,
            len_t nr_in,
        const float* W
) nogil:
    MatVec.dot(out,
        W, in_, nr_out, nr_in)
    VecVec.add_i(out,
        bias, 1.0, nr_out)


cdef void sparse_dot_plus(
    float* out,
        const float* bias,
            len_t nr_out,
        const FeatureC* feats,
            len_t nr_feat,
        const MapC* const* Ws
) nogil:
    for i in range(nr_feat):
        W = Ws[feats[i].i]
        if W is not NULL: # Shouldn't be NULL
            row = <const float*>Map_get(W, feats[i].key)
            if row is not NULL: # Can be NULL
                VecVec.add_i(out,
                    row, feats[i].value, nr_out)
    VecVec.add_i(out,
        bias, 1.0, nr_out)


cdef void d_dot(
    float* btm_diff,
        len_t nr_btm,
        const float* top_diff,
        len_t nr_top,
        const float* W,
) nogil:
    MatVec.T_dot(btm_diff,
        W, top_diff, nr_top, nr_btm)


cdef void ELU(float* out, len_t nr_out) nogil:
    cdef idx_t i
    for i in range(nr_out):
        if out[i] < 0:
            out[i] = ALPHA * (expf(out[i]) - 1)


cdef void d_ELU(float* delta, const float* signal_out, int n) nogil:
    # Backprop the ELU transformation
    # Note that this is over the function _output_, not the function
    # _input_!
    for i in range(n):
        if signal_out[i] < 0:
            delta[i] *= signal_out[i] + ALPHA


cdef void softmax(float* out, len_t nr_out) nogil:
    #w = exp(w - max(w))
    Vec.add_i(out,
        -Vec.max(out, nr_out), nr_out)
    Vec.exp_i(out,
        nr_out)
    #w = w / sum(w)
    cdef float norm = Vec.sum(out, nr_out)
    if norm != 0:
        Vec.div_i(out,
            norm, nr_out)


cdef void d_log_loss(
    float* loss,
        const float* costs,
        const float* scores,
            len_t nr_out
) nogil:
    # This assumes only one true class
    cdef idx_t i
    for i in range(nr_out):
        loss[i] = scores[i] - (costs[i] == 0)


@cython.cdivision(True)
cdef void old_adam(
    float* weights,
    float* moments,
    float* gradient,
        len_t nr_weight,
        const ConstantsC* hp
) nogil:
    cdef float beta1 = 0.90
    cdef float beta2 = 0.999
    # Add the derivative of the L2-loss to the gradient
    cdef idx_t i
    if hp.r != 0:
        VecVec.add_i(gradient,
            weights, hp.r, nr_weight)
    # This is all vectorized and in-place, so it's hard to read. See the
    # paper.
    mom1 = moments
    mom2 = &moments[nr_weight]
    Vec.mul_i(mom1,
        beta1, nr_weight)
    VecVec.add_i(mom1,
        gradient, 1-beta1, nr_weight)
    Vec.mul_i(mom2,
        beta2, nr_weight)
    VecVec.mul_i(gradient,
        gradient, nr_weight)
    VecVec.add_i(mom2,
        gradient, 1-beta2, nr_weight)
    Vec.div(gradient,
        mom1, 1-beta1, nr_weight)
    for i in range(nr_weight):
        gradient[i] /= sqrtf(mom2[i] / (1-beta2)) + EPS
    Vec.mul_i(gradient,
        hp.e, nr_weight)
    VecVec.add_i(weights,
        gradient, -1.0, nr_weight)


@cython.cdivision(True)
cdef void adam(
    float* weights, float* moments, float* gradient,
        len_t nr_weight, const ConstantsC* hp) nogil:
    cdef float beta1 = 0.90
    cdef float beta2 = 0.999
    cdef float eps = 0.000001 
    # Add the derivative of the L2-loss to the gradient
    cdef idx_t i
    if hp.r != 0:
        VecVec.add_i(gradient,
            weights, hp.r, nr_weight)
    mom1 = moments
    mom2 = &moments[nr_weight]
    Vec.mul_i(mom1,
        beta1, nr_weight) 
    VecVec.add_i(mom1,
        gradient, 1-beta1, nr_weight)
    Vec.mul_i(mom2,
        beta2, nr_weight) 
    for i in range(nr_weight):
        mom2[i] += (1-beta2) * gradient[i] * gradient[i]
    # More efficient version, from the paper
    for i in range(nr_weight):
        gradient[i] = mom1[i] / (sqrtf(mom2[i]) + eps)
    cdef float a_t = hp.e * (sqrtf(1-beta2**hp.t) / (1-beta1**hp.t))
    VecVec.add_i(weights,
        gradient, -a_t, nr_weight)


@cython.cdivision(True)
cdef void adadelta(float* weights, float* momentum, float* gradient,
        len_t nr_weight, float scale, const ConstantsC* hp) nogil:
    cdef float alpha = 0.90
    Vec.mul_i(gradient,
        scale, nr_weight)
    # Add the derivative of the L2-loss to the gradient
    cdef int i
    if hp.r != 0:
        VecVec.add_i(gradient,
            weights, hp.r, nr_weight)
    avg = momentum
    step = &momentum[nr_weight]
    Vec.mul_i(avg,
        alpha, nr_weight)
    for i in range(nr_weight):
        avg[i] += (1-alpha) * gradient[i] * gradient[i]
    for i in range(nr_weight):
        gradient[i] *= sqrtf(step[i] + EPS) / sqrtf(avg[i] + EPS)
    Vec.mul_i(step,
        alpha, nr_weight)
    VecVec.add_i(weights,
        gradient, -1.0, nr_weight)



@cython.cdivision(True)
cdef void vanilla_sgd_update_step(
    float* weights,
    float* moments,
    float* gradient,
        len_t nr_weight,
        const ConstantsC* hp
) nogil:
    '''
    Update weights with vanilla SGD
    '''
    # Add the derivative of the L2-loss to the gradient
    if hp.r != 0:
        VecVec.add_i(gradient,
            weights, hp.r, nr_weight)
    VecVec.add_i(weights,
        gradient, -hp.e, nr_weight)


########
# Batch Normalization, non-functional draft

#cdef void normalize(
#    float* x,
#    float* Ex,
#    float* Vx,
#        len_t nr_x,
#        float alpha
#) nogil:
#    # Upd EMA estimate of mean and variance
#    # See eq at the end of this:
#    # http://nfs-uxsup.csx.cam.ac.uk/~fanf2/hermes/doc/antiforgery/stats.pdf
#    cdef idx_t i
#    cdef float diff
#    cdef float incr
#    for i in range(nr_x):
#        diff = x[i] - Ex[i]
#        incr = alpha * diff
#        Vx[i] = (1.0 - alpha) * (Vx[i] + diff * incr)
#        Ex[i] += incr
#    # Normalize
#    for i in range(n):
#        x[i] = (x[i] - Ex[i]) / sqrtf(Vx[i] + EPS)
#
#
#cdef void d_normalize(
#    float* bwd,
#    float* E_dEdXh,
#    float* E_dEdXh_dot_Xh,
#        const float* Xh,
#        const float* Vx,
#            len_t n,
#        float alpha
#) nogil:
#    # Update EMA estimate of mean(dL/dX_hat)
#    Vec.mul_i(E_dEdXh,
#        alpha, n)
#    VecVec.add_i(E_dEdXh,
#        bwd, 1-alpha, n)
#    # Update EMA estimate of mean(dE/dX_hat \cdot X_hat)
#    Vec.mul_i(E_dEdXh_dot_Xh,
#        alpha, n)
#    for i in range(n):
#        E_dEdXh_dot_Xh[i] += (1-alpha) * bwd[i] * Xh[i]
#    # Simplification taken from Caffe, I think by cdoersch
#    # if X' = (X-mean(X))/sqrt(var(X)+eps), then
#    # dE/dX =
#    #   (dE/dXh - mean(dE/dXh) - mean(dE/dXh * Xh) * Xh)
#    #     ./ sqrt(var(X) + eps)
#    # bwd is dE/dXh to start with. We change it to dE/dX in-place.
#    for i in range(n):
#        bwd[i] -= E_dEdXh[i] - E_dEdXh_dot_Xh[i] * Xh[i]
#        bwd[i] /= sqrtf(Vx[i] + EPS)
#
#
#
#
#cdef void dot_plus__normalize__dot_plus__ELU(
#    float* output,
#    float* normed,
#    float* Ex,
#    float* Vx,
#        const float* bias,
#        const float* gamma,
#        len_t nr_out,
#        const float* input_,
#            len_t nr_in,
#        const weight_t* W,
#        float ema_stickiness
#) nogil:
#    dot_plus(output,
#        input_, W, bias, nr_out, nr_in)
#    normalize(normed, Ex, Vx,
#        nr_out, ema_stickiness) 
#    dot_plus(output,
#        normed, gamma, beta, nr_out, 1)
#    ELU(x_dotPlus_normalize_dotPlus_ELU,
#        nr_out)
#
#
#cdef void dELU_dDot_dNormalize_dDot(
#    float* dY,
#    float* dXh,
#    float* dX,
#    float* E_dXh,
#    float* E_dXh_Xh,
#        const float* Xh,
#        const float* Vx,
#        len_t nr_out,
#        len_t nr_in,
#        float ema_speed
#) nogil:
#    d_ELU(dY,
#        Y, nr_out) # Y = ELU(dot(G, BN(W*x+b))), i.e. our layer's final output
#    d_dot(dXh,
#        dY, gamma, nr_out, 1)
#    d_normalize(dXh, E_dXh, E_dXh_Xh,
#        Xh, Vx, nr_out, ema_speed)
#    d_dot(dX,
#        dXh, W, nr_out, nr_in)
#
#
#