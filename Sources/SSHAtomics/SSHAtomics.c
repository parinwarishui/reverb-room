#include "SSHAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct SSHMeterState {
    _Atomic(float) peak;
    _Atomic(bool) receivedSignal;
    _Atomic(bool) renderFailed;
};

SSHMeterState *ssh_meter_create(void) {
    SSHMeterState *meter = malloc(sizeof *meter);
    if (meter == NULL) return NULL;
    atomic_init(&meter->peak, 0.0f);
    atomic_init(&meter->receivedSignal, false);
    atomic_init(&meter->renderFailed, false);
    return meter;
}

void ssh_meter_destroy(SSHMeterState *meter) {
    free(meter);
}

void ssh_meter_reset(SSHMeterState *meter) {
    atomic_store_explicit(&meter->peak, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&meter->receivedSignal, false, memory_order_relaxed);
    atomic_store_explicit(&meter->renderFailed, false, memory_order_relaxed);
}

void ssh_meter_update(SSHMeterState *meter, float cyclePeak) {
    // One writer (the IO thread), so a load followed by a store is enough.
    float decayed = atomic_load_explicit(&meter->peak, memory_order_relaxed) * 0.85f;
    float clipped = cyclePeak < 1.0f ? cyclePeak : 1.0f;
    atomic_store_explicit(&meter->peak, decayed > clipped ? decayed : clipped, memory_order_relaxed);
    if (cyclePeak > 0.0f) atomic_store_explicit(&meter->receivedSignal, true, memory_order_relaxed);
}

void ssh_meter_mark_render_failure(SSHMeterState *meter) {
    atomic_store_explicit(&meter->renderFailed, true, memory_order_relaxed);
}

float ssh_meter_peak(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->peak, memory_order_relaxed);
}

bool ssh_meter_received_signal(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->receivedSignal, memory_order_relaxed);
}

bool ssh_meter_render_failed(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->renderFailed, memory_order_relaxed);
}
