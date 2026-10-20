#include "SSHAtomics.h"

#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>

struct SSHMeterState {
    _Atomic(float) peak;
    _Atomic(float) meanSquare;
    _Atomic(float) bassMeanSquare;
    _Atomic(float) trebleMeanSquare;
    _Atomic(bool) receivedSignal;
    _Atomic(bool) renderFailed;
};

SSHMeterState *ssh_meter_create(void) {
    SSHMeterState *meter = malloc(sizeof *meter);
    if (meter == NULL) return NULL;
    atomic_init(&meter->peak, 0.0f);
    atomic_init(&meter->meanSquare, 0.0f);
    atomic_init(&meter->bassMeanSquare, 0.0f);
    atomic_init(&meter->trebleMeanSquare, 0.0f);
    atomic_init(&meter->receivedSignal, false);
    atomic_init(&meter->renderFailed, false);
    return meter;
}

void ssh_meter_destroy(SSHMeterState *meter) {
    free(meter);
}

void ssh_meter_reset(SSHMeterState *meter) {
    atomic_store_explicit(&meter->peak, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&meter->meanSquare, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&meter->bassMeanSquare, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&meter->trebleMeanSquare, 0.0f, memory_order_relaxed);
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

void ssh_meter_update_rms(SSHMeterState *meter, float cycleMeanSquare) {
    // One writer (the IO thread). At ~94 cycles/s (512 frames, 48 kHz), keeping
    // 80% of the old value gives a time constant of roughly 50 ms.
    float old = atomic_load_explicit(&meter->meanSquare, memory_order_relaxed);
    float clipped = cycleMeanSquare < 1.0f ? cycleMeanSquare : 1.0f;
    atomic_store_explicit(&meter->meanSquare, old * 0.8f + clipped * 0.2f, memory_order_relaxed);
}

static void decaying_peak(_Atomic(float) *value, float cycle) {
    // One writer (the IO thread). Keeping 70% per cycle (~94 cycles/s) fades a
    // hit to a tenth in about 70 ms.
    float decayed = atomic_load_explicit(value, memory_order_relaxed) * 0.7f;
    float clipped = cycle < 1.0f ? cycle : 1.0f;
    atomic_store_explicit(value, decayed > clipped ? decayed : clipped, memory_order_relaxed);
}

void ssh_meter_update_bands(SSHMeterState *meter, float bassMeanSquare, float trebleMeanSquare) {
    decaying_peak(&meter->bassMeanSquare, bassMeanSquare);
    decaying_peak(&meter->trebleMeanSquare, trebleMeanSquare);
}

void ssh_meter_mark_render_failure(SSHMeterState *meter) {
    atomic_store_explicit(&meter->renderFailed, true, memory_order_relaxed);
}

float ssh_meter_peak(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->peak, memory_order_relaxed);
}

float ssh_meter_rms(SSHMeterState *meter) {
    return sqrtf(atomic_load_explicit(&meter->meanSquare, memory_order_relaxed));
}

float ssh_meter_bass_rms(SSHMeterState *meter) {
    return sqrtf(atomic_load_explicit(&meter->bassMeanSquare, memory_order_relaxed));
}

float ssh_meter_treble_rms(SSHMeterState *meter) {
    return sqrtf(atomic_load_explicit(&meter->trebleMeanSquare, memory_order_relaxed));
}

bool ssh_meter_received_signal(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->receivedSignal, memory_order_relaxed);
}

bool ssh_meter_render_failed(SSHMeterState *meter) {
    return atomic_load_explicit(&meter->renderFailed, memory_order_relaxed);
}
