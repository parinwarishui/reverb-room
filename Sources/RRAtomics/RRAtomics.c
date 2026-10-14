#include "RRAtomics.h"
#include <stdatomic.h>

float rr_load_float(float *p) {
    return atomic_load_explicit((_Atomic float *)p, memory_order_relaxed);
}

void rr_store_float(float *p, float value) {
    atomic_store_explicit((_Atomic float *)p, value, memory_order_relaxed);
}

uint32_t rr_load_u32(uint32_t *p) {
    return atomic_load_explicit((_Atomic uint32_t *)p, memory_order_relaxed);
}

void rr_add_u32(uint32_t *p, uint32_t value) {
    atomic_fetch_add_explicit((_Atomic uint32_t *)p, value, memory_order_relaxed);
}

uint32_t rr_load_u32_acquire(uint32_t *p) {
    return atomic_load_explicit((_Atomic uint32_t *)p, memory_order_acquire);
}

void rr_store_u32_release(uint32_t *p, uint32_t value) {
    atomic_store_explicit((_Atomic uint32_t *)p, value, memory_order_release);
}

void *rr_load_ptr(void **slot) {
    return atomic_load_explicit((void *_Atomic *)slot, memory_order_acquire);
}

void *rr_exchange_ptr(void **slot, void *value) {
    return atomic_exchange_explicit((void *_Atomic *)slot, value, memory_order_acq_rel);
}
