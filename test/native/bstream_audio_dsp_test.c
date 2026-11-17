#include "BStreamAudioDSP.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PI 3.14159265358979323846264338327950288
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); \
} } while (0)

static double amplitude(const float *samples, size_t frames, double rate, double frequency) {
    double real = 0, imaginary = 0;
    const size_t first = frames / 2;
    for (size_t frame = first; frame < frames; ++frame) {
        double phase = 2 * PI * frequency * (double)frame / rate;
        real += samples[frame] * cos(phase);
        imaginary -= samples[frame] * sin(phase);
    }
    return 2 * sqrt(real * real + imaginary * imaginary) / (double)(frames - first);
}

static void test_frequency_response(void) {
    const unsigned rates[] = {44100, 48000, 96000};
    for (unsigned r = 0; r < sizeof(rates) / sizeof(rates[0]); ++r) {
        double rate = rates[r];
        size_t frames = rates[r];
        float *samples = (float *)malloc(frames * sizeof(float));
        CHECK(samples != NULL);
        for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
            for (int boost = 0; boost <= 1; ++boost) {
                double gains[5] = {0};
                gains[band] = boost ? 6 : -6;
                for (size_t frame = 0; frame < frames; ++frame)
                    samples[frame] = (float)(.2 * sin(2 * PI * BStreamDSPFrequencies[band] * (double)frame / rate));
                BStreamDSP *dsp = BStreamDSPCreate(rate, 1);
                CHECK(dsp && BStreamDSPSetEqualizer(dsp, true, gains, 12, true));
                void *buffers[] = {samples};
                BStreamDSPProcessFloat32(dsp, buffers, frames, true);
                double db = 20 * log10(amplitude(samples, frames, rate, BStreamDSPFrequencies[band]) / .2);
                CHECK(fabs(db - (boost ? 0 : -6)) < .04);
                BStreamDSPStatus status = BStreamDSPGetStatus(dsp);
                CHECK(status.enabled && status.preampDb == (boost ? -6 : 0));
                CHECK(status.processedFrames == frames && status.appliedRevision == 12);
                BStreamDSPDestroy(dsp);
            }
        }
        free(samples);
    }
}

static void test_bypass_is_exact(void) {
    uint32_t words[] = {0, 0x80000000u, 0x7fc00001u, 0x7fa12345u, 0x7f800000u, 0xff800000u,
                        0x40000000u, 0x12345678u, 0xffffffffu, 0x00000001u};
    uint32_t expected[sizeof(words) / sizeof(words[0])];
    memcpy(expected, words, sizeof(words));
    double gains[5] = {0};
    BStreamDSP *dsp = BStreamDSPCreate(48000, 1);
    void *buffers[] = {words};
    BStreamDSPProcessFloat32(dsp, buffers, sizeof(words) / sizeof(words[0]), true);
    CHECK(memcmp(words, expected, sizeof(words)) == 0);
    CHECK(BStreamDSPSetEqualizer(dsp, true, gains, 1, false));
    CHECK(BStreamDSPIsBypassed(dsp));
    BStreamDSPProcessFloat32(dsp, buffers, sizeof(words) / sizeof(words[0]), false);
    CHECK(memcmp(words, expected, sizeof(words)) == 0);
    gains[0] = 12;
    CHECK(BStreamDSPSetEqualizer(dsp, false, gains, 2, false));
    BStreamDSPProcessInt16(dsp, buffers, sizeof(words) / (sizeof(int16_t)), true);
    BStreamDSPProcessInt32(dsp, buffers, sizeof(words) / sizeof(int32_t), true);
    CHECK(memcmp(words, expected, sizeof(words)) == 0);
    BStreamDSPDestroy(dsp);

    uint64_t doubles[] = {UINT64_C(0x7ff8000000000001), UINT64_C(0x8000000000000000),
                          UINT64_C(0xffffffffffffffff), UINT64_C(0x4000000000000000)};
    uint64_t original[4];
    memcpy(original, doubles, sizeof(doubles));
    dsp = BStreamDSPCreate(48000, 1);
    buffers[0] = doubles;
    BStreamDSPProcessFloat64(dsp, buffers, 4, true);
    CHECK(memcmp(doubles, original, sizeof(doubles)) == 0);
    BStreamDSPDestroy(dsp);
}

static void test_channels_and_pcm_types(void) {
    double gains[5] = {0, 0, -6, 0, 0};
    const size_t frames = 4800;
    double *planar[6];
    void *planes[6];
    for (unsigned channel = 0; channel < 6; ++channel) {
        planar[channel] = (double *)calloc(frames, sizeof(double));
        CHECK(planar[channel]);
        planes[channel] = planar[channel];
        if (channel == 4)
            for (size_t frame = 0; frame < frames; ++frame)
                planar[channel][frame] = .2 * sin(2 * PI * 910 * (double)frame / 48000);
    }
    BStreamDSP *dsp = BStreamDSPCreate(48000, 6);
    CHECK(BStreamDSPSetEqualizer(dsp, true, gains, 1, true));
    BStreamDSPProcessFloat64(dsp, planes, frames, false);
    double maximum = 0;
    for (unsigned channel = 0; channel < 6; ++channel) {
        for (size_t frame = frames / 2; frame < frames; ++frame) {
            if (channel == 4) maximum = fmax(maximum, fabs(planar[channel][frame]));
            else CHECK(planar[channel][frame] == 0);
        }
        free(planar[channel]);
    }
    CHECK(fabs(maximum - .2 * pow(10, -6.0 / 20)) < .0001);
    BStreamDSPDestroy(dsp);

    int16_t pcm16[9600];
    int32_t pcm32[9600];
    for (size_t frame = 0; frame < frames; ++frame) {
        const double value = .2 * sin(2 * PI * 910 * (double)frame / 48000);
        pcm16[frame * 2] = (int16_t)round(value * 32768);
        pcm32[frame * 2] = (int32_t)round(value * 2147483648.0);
        pcm16[frame * 2 + 1] = 0;
        pcm32[frame * 2 + 1] = 0;
    }
    dsp = BStreamDSPCreate(48000, 2);
    CHECK(BStreamDSPSetEqualizer(dsp, true, gains, 1, true));
    void *input[] = {pcm16};
    BStreamDSPProcessInt16(dsp, input, frames, true);
    maximum = 0;
    for (size_t frame = frames / 2; frame < frames; ++frame) {
        CHECK(pcm16[frame * 2 + 1] == 0);
        maximum = fmax(maximum, fabs(pcm16[frame * 2] / 32768.0));
    }
    CHECK(fabs(maximum - .2 * pow(10, -6.0 / 20)) < .0001);
    BStreamDSPReset(dsp);
    input[0] = pcm32;
    BStreamDSPProcessInt32(dsp, input, frames, true);
    maximum = 0;
    for (size_t frame = frames / 2; frame < frames; ++frame) {
        CHECK(pcm32[frame * 2 + 1] == 0);
        maximum = fmax(maximum, fabs(pcm32[frame * 2] / 2147483648.0));
    }
    CHECK(fabs(maximum - .2 * pow(10, -6.0 / 20)) < .0001);
    BStreamDSPDestroy(dsp);
}

static void test_glide_reset_and_validation(void) {
    BStreamDSP *dsp = BStreamDSPCreate(48000, 1);
    double gains[5] = {0, 0, -6, 0, 0};
    CHECK(BStreamDSPSetEqualizer(dsp, true, gains, 4, false));
    float samples[1200];
    for (unsigned frame = 0; frame < 1200; ++frame) samples[frame] = .2f;
    void *buffers[] = {samples};
    BStreamDSPProcessFloat32(dsp, buffers, 600, true);
    CHECK(BStreamDSPGetStatus(dsp).appliedRevision == UINT64_MAX);
    buffers[0] = samples + 600;
    BStreamDSPProcessFloat32(dsp, buffers, 600, true);
    CHECK(BStreamDSPGetStatus(dsp).appliedRevision == 4);
    gains[0] = NAN;
    CHECK(!BStreamDSPSetEqualizer(dsp, true, gains, 9, false));
    CHECK(BStreamDSPGetStatus(dsp).revision == 4);
    gains[0] = 0;
    CHECK(BStreamDSPSetEqualizer(dsp, false, gains, 5, false));
    buffers[0] = samples;
    BStreamDSPProcessFloat32(dsp, buffers, 1200, true);
    CHECK(BStreamDSPIsBypassed(dsp));
    CHECK(BStreamDSPGetStatus(dsp).appliedRevision == 5);
    BStreamDSPDestroy(dsp);

    dsp = BStreamDSPCreate(8000, 1);
    double highBand[5] = {0, 0, 0, 0, -6};
    CHECK(BStreamDSPSetEqualizer(dsp, true, highBand, 8, true));
    float original[1200];
    for (unsigned frame = 0; frame < 1200; ++frame)
        samples[frame] = original[frame] = (float)(.2 * sin(2 * PI * 400 * frame / 8000));
    buffers[0] = samples;
    BStreamDSPProcessFloat32(dsp, buffers, 1200, true);
    CHECK(memcmp(samples, original, sizeof(samples)) == 0);
    BStreamDSPReset(dsp);
    CHECK(BStreamDSPGetStatus(dsp).appliedRevision == UINT64_MAX);
    BStreamDSPDestroy(dsp);
    CHECK(!BStreamDSPCreate(NAN, 1) && !BStreamDSPCreate(48000, 0));
    CHECK(!BStreamDSPCreate(48000, 9));
}

typedef struct { BStreamSilenceInterval values[32]; unsigned count; } Intervals;

static void collect(BStreamSilence *detector, Intervals *intervals) {
    BStreamSilenceInterval interval;
    while (BStreamSilencePopInterval(detector, &interval)) {
        CHECK(interval.endFrame > interval.startFrame);
        if (intervals->count && intervals->values[intervals->count - 1].startFrame == interval.startFrame) {
            CHECK(interval.endFrame >= intervals->values[intervals->count - 1].endFrame);
            intervals->values[intervals->count - 1] = interval;
        } else {
            CHECK(intervals->count < 32);
            intervals->values[intervals->count++] = interval;
        }
    }
    CHECK(BStreamSilenceDroppedIntervals(detector) == 0);
}

static void feed(BStreamSilence *detector, double seconds, double peak, unsigned chunk,
                 Intervals *intervals) {
    float samples[4096];
    const void *buffers[] = {samples};
    uint64_t remaining = (uint64_t)round(seconds * 48000);
    uint64_t position = BStreamSilenceAnalyzedFrames(detector);
    CHECK(chunk > 0 && chunk <= 4096);
    while (remaining) {
        unsigned count = remaining < chunk ? (unsigned)remaining : chunk;
        for (unsigned frame = 0; frame < count; ++frame)
            samples[frame] = (float)(peak / 32768.0 * sin(2 * PI * 440 * (double)(position + frame) / 48000));
        BStreamSilenceProcessFloat32(detector, buffers, count, true);
        collect(detector, intervals);
        remaining -= count;
        position += count;
    }
}

static void test_silence_music_and_margins(void) {
    for (unsigned chunk = 37; chunk <= 4096; chunk = chunk == 37 ? 1024 : chunk == 1024 ? 4096 : 4097) {
        BStreamSilence *detector = BStreamSilenceCreate(48000, 1, true);
        CHECK(detector);
        Intervals intervals = {0};
        feed(detector, 1.7, 0, chunk, &intervals);
        CHECK(intervals.count == 0);
        feed(detector, .2, 0, chunk, &intervals);
        CHECK(intervals.count == 1);
        CHECK(intervals.values[0].startFrame == 7200);
        CHECK(intervals.values[0].endFrame <= (uint64_t)(1.9 * 48000 - 12000));
        feed(detector, .5, 2800, chunk, &intervals);
        CHECK(intervals.values[0].endFrame <= 79248); /* sine begins at a zero crossing */
        BStreamSilenceDestroy(detector);

        detector = BStreamSilenceCreate(48000, 1, true);
        intervals.count = 0;
        feed(detector, .5, 2800, chunk, &intervals);
        feed(detector, 4.0, 0, chunk, &intervals);
        feed(detector, .5, 2800, chunk, &intervals);
        BStreamSilenceFinish(detector);
        collect(detector, &intervals);
        CHECK(intervals.count == 0);
        BStreamSilenceDestroy(detector);

        detector = BStreamSilenceCreate(48000, 1, true);
        intervals.count = 0;
        feed(detector, .5, 2800, chunk, &intervals);
        feed(detector, 5.0, 0, chunk, &intervals);
        CHECK(intervals.count == 1); /* confirmed before EOF, usable as lookahead */
        feed(detector, .5, 2800, chunk, &intervals);
        BStreamSilenceFinish(detector);
        collect(detector, &intervals);
        CHECK(intervals.count == 1);
        CHECK(fabs(intervals.values[0].startFrame / 48000.0 - .65) < .01);
        CHECK(fabs(intervals.values[0].endFrame / 48000.0 - 5.25) < .01);
        BStreamSilenceDestroy(detector);
    }

    BStreamSilence *detector = BStreamSilenceCreate(48000, 1, true);
    Intervals intervals = {0};
    feed(detector, 6, 80, 1024, &intervals);
    BStreamSilenceFinish(detector);
    collect(detector, &intervals);
    CHECK(intervals.count == 0); /* low sine RMS below -52, peak veto saves music */
    BStreamSilenceDestroy(detector);

    detector = BStreamSilenceCreate(48000, 1, true);
    feed(detector, .5, 2800, 1024, &intervals);
    feed(detector, 4.4, 0, 1024, &intervals);
    feed(detector, .5, 2800, 1024, &intervals);
    BStreamSilenceFinish(detector);
    collect(detector, &intervals);
    CHECK(intervals.count == 0); /* envelope lag cannot turn 4.4 sec into 4.5 */
    BStreamSilenceDestroy(detector);

    detector = BStreamSilenceCreate(48000, 1, true);
    feed(detector, .5, 2800, 1024, &intervals);
    feed(detector, 5.0, 0, 1024, &intervals);
    feed(detector, 1.0, 160, 1024, &intervals); /* RMS stays in hysteresis */
    feed(detector, 5.0, 0, 1024, &intervals);
    feed(detector, .5, 2800, 1024, &intervals);
    BStreamSilenceFinish(detector);
    collect(detector, &intervals);
    CHECK(intervals.count == 2);
    CHECK(fabs(intervals.values[0].endFrame / 48000.0 - 5.25) < .01);
    CHECK(fabs(intervals.values[1].startFrame / 48000.0 - 6.65) < .01);
    CHECK(fabs(intervals.values[1].endFrame / 48000.0 - 11.25) < .01);
    BStreamSilenceDestroy(detector);
}

static void test_seek_and_sparse_channel_guard(void) {
    BStreamSilence *detector = BStreamSilenceCreate(48000, 1, true);
    Intervals intervals = {0};
    BStreamSilenceReset(detector, 480000, false);
    feed(detector, 2.0, 0, 1024, &intervals);
    CHECK(intervals.count == 0);
    feed(detector, 3.0, 0, 1024, &intervals);
    CHECK(intervals.count == 1);
    CHECK(intervals.values[0].startFrame == 487200);
    BStreamSilenceDestroy(detector);

    detector = BStreamSilenceCreate(48000, 2, true);
    float left[1024], right[1024];
    memset(left, 0, sizeof(left));
    const void *buffers[] = {left, right};
    intervals.count = 0;
    for (unsigned block = 0; block < 300; ++block) {
        for (unsigned frame = 0; frame < 1024; ++frame)
            right[frame] = (float)(80 / 32768.0 * sin(2 * PI * 440 * (block * 1024 + frame) / 48000.0));
        BStreamSilenceProcessFloat32(detector, buffers, 1024, false);
        collect(detector, &intervals);
    }
    BStreamSilenceFinish(detector);
    collect(detector, &intervals);
    CHECK(intervals.count == 0);
    BStreamSilenceDestroy(detector);
}

int main(void) {
    test_frequency_response();
    test_bypass_is_exact();
    test_channels_and_pcm_types();
    test_glide_reset_and_validation();
    test_silence_music_and_margins();
    test_seek_and_sparse_channel_guard();
    puts("BStream portable audio DSP: all 6 test groups passed");
    return 0;
}
