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
/// Real-time thread: feed one cycle's mean square (average of sample²). Kept as a
/// short exponential average, so the UI reads a steady RMS, not one cycle's noise.
void ssh_meter_update_rms(SSHMeterState *_Nonnull meter, float cycleMeanSquare);
/// Real-time thread: one cycle's mean square in the bass and treble bands. Kept as
/// a fast-decaying peak (a hit is held, then fades within ~50 ms), so a drum hit
/// between two UI reads isn't missed.
void ssh_meter_update_bands(SSHMeterState *_Nonnull meter, float bassMeanSquare, float trebleMeanSquare);
/// Real-time thread: the engine has failed to render for too long.
void ssh_meter_mark_render_failure(SSHMeterState *_Nonnull meter);

float ssh_meter_peak(SSHMeterState *_Nonnull meter);
/// Linear RMS (0...1) of the short exponential average above.
float ssh_meter_rms(SSHMeterState *_Nonnull meter);
/// Linear RMS (0...1) of the bass and treble bands, from the decaying peaks above.
float ssh_meter_bass_rms(SSHMeterState *_Nonnull meter);
float ssh_meter_treble_rms(SSHMeterState *_Nonnull meter);
bool ssh_meter_received_signal(SSHMeterState *_Nonnull meter);
bool ssh_meter_render_failed(SSHMeterState *_Nonnull meter);

#endif
