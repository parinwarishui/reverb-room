//
//  SSHAtomics.h
//  Lock-free state shared between the real-time audio thread and the rest of the
//  app. Written in C because Swift's own atomics (Synchronization) need macOS 15.
//

#ifndef SSH_ATOMICS_H
#define SSH_ATOMICS_H

#include <stdbool.h>

/// Opaque; defined in SSHAtomics.c. Every access is a relaxed atomic load or store:
/// no locks the audio thread could wait on, and no torn values.
typedef struct SSHMeterState SSHMeterState;

SSHMeterState *_Nullable ssh_meter_create(void);
void ssh_meter_destroy(SSHMeterState *_Nonnull meter);

void ssh_meter_reset(SSHMeterState *_Nonnull meter);

/// Real-time thread: decaying peak, plus the "signal seen" flag if cyclePeak > 0.
void ssh_meter_update(SSHMeterState *_Nonnull meter, float cyclePeak);
/// Real-time thread: the engine has failed to render for too long.
void ssh_meter_mark_render_failure(SSHMeterState *_Nonnull meter);

float ssh_meter_peak(SSHMeterState *_Nonnull meter);
bool ssh_meter_received_signal(SSHMeterState *_Nonnull meter);
bool ssh_meter_render_failed(SSHMeterState *_Nonnull meter);

#endif
