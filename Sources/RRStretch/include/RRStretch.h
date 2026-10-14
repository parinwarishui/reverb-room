#ifndef RRSTRETCH_H
#define RRSTRETCH_H

// A C interface to Signalsmith Stretch, used as a polyphonic pitch shifter.
// Create and destroy off the audio thread; everything else is real-time safe.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RRStretch RRStretch;

RRStretch *rr_stretch_create(int channels, double sampleRate);
void rr_stretch_destroy(RRStretch *stretch);

/// Frames between a sample going in and the same moment coming out.
int rr_stretch_latency(const RRStretch *stretch);

void rr_stretch_set_semitones(RRStretch *stretch, float semitones);

/// `frames` frames in, `frames` frames out; one pointer per channel each way.
void rr_stretch_process(RRStretch *stretch, const float *const *inputs, float *const *outputs, int frames);

#ifdef __cplusplus
}
#endif

#endif
