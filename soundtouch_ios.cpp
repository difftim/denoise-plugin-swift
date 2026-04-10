#include "SoundTouch.h"
#include <cstring>

using namespace soundtouch;

// Speech-mode settings, matching JS/Android targets.
#define ST_SEQUENCE_MS   40
#define ST_SEEKWINDOW_MS 15
#define ST_OVERLAP_MS     8

static const float kInt16ToFloat = 1.0f / 32768.0f;
static const float kFloatToInt16 = 32768.0f;

struct STState {
    SoundTouch st;

    STState(int sampleRate) {
        st.setSampleRate((uint)sampleRate);
        st.setChannels(1);
        st.setSetting(SETTING_SEQUENCE_MS,   ST_SEQUENCE_MS);
        st.setSetting(SETTING_SEEKWINDOW_MS, ST_SEEKWINDOW_MS);
        st.setSetting(SETTING_OVERLAP_MS,    ST_OVERLAP_MS);
    }
};

extern "C" {

STState *st_create(int sample_rate) {
    return new STState(sample_rate);
}

void st_destroy(STState *state) {
    delete state;
}

void st_set_pitch_semitones(STState *state, float semitones) {
    state->st.setPitchSemiTones(semitones);
}

/**
 * Process `num_samples` float32 samples in-place.
 * Samples are in int16 scale ([-32768, 32767]).
 * Returns 1 when output was written; 0 during FIFO warmup (samples left unchanged).
 */
int st_process_frame(STState *state, float *samples, int num_samples) {
    // Normalize to [-1, 1] into a local buffer; leave `samples` intact for warmup path.
    float normalized[2048];
    const int n = num_samples < 2048 ? num_samples : 2048;
    for (int i = 0; i < n; i++)
        normalized[i] = samples[i] * kInt16ToFloat;

    state->st.putSamples(normalized, (uint)n);

    float out[2048];
    uint received = state->st.receiveSamples(out, (uint)n);

    if ((int)received == n) {
        for (int i = 0; i < n; i++)
            samples[i] = out[i] * kFloatToInt16;
        return 1;
    }

    // Warmup: FIFO not yet full — leave original samples unchanged.
    return 0;
}

} // extern "C"
