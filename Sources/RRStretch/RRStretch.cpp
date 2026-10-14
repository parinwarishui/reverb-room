#include "RRStretch.h"

#include "vendor/signalsmith-stretch/signalsmith-stretch.h"

struct RRStretch {
    // Fixed seed: no std::random_device, and identical runs give identical output.
    signalsmith::stretch::SignalsmithStretch<float> engine{0x5EED};
    float sampleRate = 48000;
};

extern "C" {

RRStretch *rr_stretch_create(int channels, double sampleRate) {
    auto *stretch = new RRStretch();
    stretch->sampleRate = float(sampleRate);
    // 120 ms analysis blocks every 30 ms: Signalsmith's default, tuned for music.
    // Split computation spreads each block's FFT work across several audio
    // callbacks instead of doing it all in one, so no single callback runs long.
    stretch->engine.presetDefault(channels, float(sampleRate), true);
    return stretch;
}

void rr_stretch_destroy(RRStretch *stretch) {
    delete stretch;
}

int rr_stretch_latency(const RRStretch *stretch) {
    return stretch->engine.inputLatency() + stretch->engine.outputLatency();
}

void rr_stretch_set_semitones(RRStretch *stretch, float semitones) {
    // Tonality limit 8 kHz (the library's recommended value): a non-linear
    // frequency map that moves the top end less than the pitch, so cymbals and
    // air keep more of their original timbre instead of turning dull or metallic.
    stretch->engine.setTransposeSemitones(semitones, 8000.0f / stretch->sampleRate);
}

void rr_stretch_process(RRStretch *stretch, const float *const *inputs, float *const *outputs, int frames) {
    stretch->engine.process(inputs, frames, outputs, frames);
}

}
