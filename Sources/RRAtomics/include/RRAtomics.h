#ifndef RRATOMICS_H
#define RRATOMICS_H

#include <stdint.h>

// Lock-free loads and stores for state shared with the real-time audio thread.
// Each pointer must point at storage that only these functions touch.

float rr_load_float(float *p);
void rr_store_float(float *p, float value);

uint32_t rr_load_u32(uint32_t *p);
void rr_add_u32(uint32_t *p, uint32_t value);

uint32_t rr_load_u32_acquire(uint32_t *p);
void rr_store_u32_release(uint32_t *p, uint32_t value);

void *rr_load_ptr(void **slot);
void *rr_exchange_ptr(void **slot, void *value);

#endif
