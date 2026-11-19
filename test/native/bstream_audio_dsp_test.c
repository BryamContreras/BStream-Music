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
                double gains[BSTREAM_DSP_BANDS] = {0};
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
    double gains[BSTREAM_DSP_BANDS] = {0};
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

static void test_combined_boost_headroom(void) {
    double gains[BSTREAM_DSP_BANDS];
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) gains[band] = 6;
    CHECK(fabs(BStreamDSPHeadroomDb(gains) - -10.977777129356811) < .000001);
    BStreamDSP *dsp = BStreamDSPCreate(48000, 1);
    CHECK(dsp && BStreamDSPSetEqualizer(dsp, true, gains, 1, true));
    const size_t frames = 36000;
    float *samples = (float *)malloc(frames * sizeof(float));
    CHECK(samples);
    for (size_t frame = 0; frame < frames; ++frame)
        samples[frame] = (float)(.8 * sin(2 * PI * 1000 * (double)frame / 48000));
    void *buffers[] = {samples};
    BStreamDSPProcessFloat32(dsp, buffers, frames, true);
    double maximum = 0;
    for (size_t frame = 0; frame < frames; ++frame)
        maximum = fmax(maximum, fabs(samples[frame]));
    CHECK(maximum < .85);
    CHECK(amplitude(samples, frames, 48000, 1000) < .8);
    CHECK(fabs(BStreamDSPGetStatus(dsp).preampDb - -10.977777129356811) < .000001);
    free(samples);
    BStreamDSPDestroy(dsp);

    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) gains[band] = -12;
    gains[4] = gains[5] = 6;
    CHECK(fabs(BStreamDSPHeadroomDb(gains) - -8.204714309118318) < .000001);
    gains[4] = -12;
    CHECK(BStreamDSPHeadroomDb(gains) == -6);
}

static void test_channels_and_pcm_types(void) {
    double gains[BSTREAM_DSP_BANDS] = {0, 0, 0, 0, 0, -6, 0, 0, 0, 0};
    const size_t frames = 4800;
    double *planar[6];
    void *planes[6];
    for (unsigned channel = 0; channel < 6; ++channel) {
        planar[channel] = (double *)calloc(frames, sizeof(double));
        CHECK(planar[channel]);
        planes[channel] = planar[channel];
        if (channel == 4)
            for (size_t frame = 0; frame < frames; ++frame)
                planar[channel][frame] = .2 * sin(2 * PI * 1000 * (double)frame / 48000);
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
        const double value = .2 * sin(2 * PI * 1000 * (double)frame / 48000);
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
    double gains[BSTREAM_DSP_BANDS] = {0, 0, 0, 0, 0, -6, 0, 0, 0, 0};
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
    double highBand[BSTREAM_DSP_BANDS] = {0, 0, 0, 0, 0, 0, 0, 0, 0, -6};
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

static void test_neutral_sections_preserve_fragmented_tails(void) {
    /* Retiring a neutral section is safe only after its two delay elements
     * drain. Exercise immediate changes, the 25 ms boundary, reset, planar
     * routing and block sizes shorter than that residual tail. */
    enum { frames = 4096, channels = 2 };
    float input[frames * channels], whole[frames * channels], fragmented[frames * channels];
    float warm_whole[frames * channels], warm_fragmented[frames * channels];
    const size_t chunks[] = {1, 1198, 1, 1, 1, 2, 1, 17, 511, 3, 7};
    for (unsigned i = 0; i < frames * channels; ++i)
        input[i] = (float)(.08 * sin(2 * PI * 997 * i / 96000.0) + .001);
    for (unsigned planar = 0; planar < 2; ++planar) {
        for (unsigned immediate = 0; immediate < 2; ++immediate) {
            BStreamDSP *left = BStreamDSPCreate(48000, channels);
            BStreamDSP *right = BStreamDSPCreate(48000, channels);
            CHECK(left && right);
            double previous[BSTREAM_DSP_BANDS], sparse[BSTREAM_DSP_BANDS] = {0};
            for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) previous[band] = -3;
            sparse[7] = 6;
            CHECK(BStreamDSPSetEqualizer(left, true, previous, 1, true));
            CHECK(BStreamDSPSetEqualizer(right, true, previous, 1, true));
            memcpy(warm_whole, input, sizeof(input));
            memcpy(warm_fragmented, input, sizeof(input));
            void *warm_left[] = {warm_whole, warm_whole + frames};
            void *warm_right[] = {warm_fragmented, warm_fragmented + frames};
            BStreamDSPProcessFloat32(left, warm_left, frames, !planar);
            BStreamDSPProcessFloat32(right, warm_right, frames, !planar);
            CHECK(BStreamDSPSetEqualizer(left, true, sparse, 2, immediate != 0));
            CHECK(BStreamDSPSetEqualizer(right, true, sparse, 2, immediate != 0));
            memcpy(whole, input, sizeof(input));
            memcpy(fragmented, input, sizeof(input));
            void *left_buffers[] = {whole, whole + frames};
            BStreamDSPProcessFloat32(left, left_buffers, frames, !planar);
            size_t cursor = 0, chunk = 0;
            while (cursor < frames) {
                size_t count = chunks[chunk++ % (sizeof(chunks) / sizeof(chunks[0]))];
                if (count > frames - cursor) count = frames - cursor;
                void *right_buffers[] = {
                    fragmented + (planar ? cursor : cursor * channels),
                    fragmented + frames + cursor,
                };
                BStreamDSPProcessFloat32(right, right_buffers, count, !planar);
                cursor += count;
            }
            CHECK(memcmp(whole, fragmented, sizeof(whole)) == 0);
            CHECK(BStreamDSPGetStatus(left).appliedRevision == 2);
            CHECK(BStreamDSPGetStatus(right).appliedRevision == 2);
            BStreamDSPReset(left);
            BStreamDSPReset(right);
            memcpy(whole, input, sizeof(input));
            memcpy(fragmented, input, sizeof(input));
            void *reset_left[] = {whole, whole + frames};
            void *reset_right[] = {fragmented, fragmented + frames};
            BStreamDSPProcessFloat32(left, reset_left, frames, !planar);
            BStreamDSPProcessFloat32(right, reset_right, frames, !planar);
            CHECK(memcmp(whole, fragmented, sizeof(whole)) == 0);
            BStreamDSPDestroy(left);
            BStreamDSPDestroy(right);
        }
    }
}

static void test_sparse_identity_keeps_ieee_zero_history(void) {
    enum { frames = 384, channels = 2 };
    const double rates[] = {8000, 48000};
    for (unsigned rate_index = 0; rate_index < 2; ++rate_index) {
        const double rate = rates[rate_index];
        /* At 8 kHz the adjusted high section is beyond Nyquist, leaving ten
         * identities in an active processor. At 48 kHz one audible section
         * also checks skipped gaps both before and after a live biquad. */
        const unsigned adjusted = rate_index ? 4 : BSTREAM_DSP_BANDS - 1;
        double gains[BSTREAM_DSP_BANDS] = {0};
        gains[adjusted] = -6;
        double coefficients[BSTREAM_DSP_BANDS][5] = {{0}};
        double z1[BSTREAM_DSP_BANDS][channels] = {{0}};
        double z2[BSTREAM_DSP_BANDS][channels] = {{0}};
        for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) coefficients[band][0] = 1;
        if (rate_index) {
            const double a = pow(10, -6.0 / 40);
            const double omega = 2 * PI * BStreamDSPFrequencies[adjusted] / rate;
            const double alpha = sin(omega) / 2;
            const double a0 = 1 + alpha / a;
            coefficients[adjusted][0] = (1 + alpha * a) / a0;
            coefficients[adjusted][1] = -2 * cos(omega) / a0;
            coefficients[adjusted][2] = (1 - alpha * a) / a0;
            coefficients[adjusted][3] = -2 * cos(omega) / a0;
            coefficients[adjusted][4] = (1 - alpha / a) / a0;
        }
        double input[frames * channels], expected[frames * channels], actual[frames * channels];
        for (unsigned i = 0; i < frames * channels; ++i) {
            input[i] = i % 3 ? -0.0 : 0.0;
            if (i > 256 && i % 127 == 0) input[i] = .01;
            double sample = input[i];
            const unsigned channel = i % channels;
            for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
                const double *c = coefficients[band];
                const double filtered = c[0] * sample + z1[band][channel];
                z1[band][channel] = c[1] * sample - c[3] * filtered + z2[band][channel];
                z2[band][channel] = c[2] * sample - c[4] * filtered;
                sample = filtered;
            }
            expected[i] = sample;
        }
        memcpy(actual, input, sizeof(input));
        BStreamDSP *dsp = BStreamDSPCreate(rate, channels);
        CHECK(dsp && BStreamDSPSetEqualizer(dsp, true, gains, 1, true));
        const size_t chunks[] = {1, 2, 1, 47, 3, 1, 11};
        size_t cursor = 0, chunk = 0;
        while (cursor < frames) {
            size_t count = chunks[chunk++ % (sizeof(chunks) / sizeof(chunks[0]))];
            if (count > frames - cursor) count = frames - cursor;
            void *buffers[] = {actual + cursor * channels};
            BStreamDSPProcessFloat64(dsp, buffers, count, true);
            cursor += count;
        }
        CHECK(memcmp(expected, actual, sizeof(expected)) == 0);
        BStreamDSPDestroy(dsp);
        float output32[frames * channels];
        for (unsigned i = 0; i < frames * channels; ++i) output32[i] = (float)input[i];
        dsp = BStreamDSPCreate(rate, channels);
        CHECK(dsp && BStreamDSPSetEqualizer(dsp, true, gains, 1, true));
        void *buffers32[] = {output32};
        BStreamDSPProcessFloat32(dsp, buffers32, frames, true);
        /* The exact signed-zero prefix is independent of float rounding. */
        for (unsigned i = 0; i < 256; ++i) {
            const float reference = (float)expected[i];
            CHECK(memcmp(&reference, &output32[i], sizeof(reference)) == 0);
        }
        BStreamDSPDestroy(dsp);
    }
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
    test_combined_boost_headroom();
    test_channels_and_pcm_types();
    test_glide_reset_and_validation();
    test_neutral_sections_preserve_fragmented_tails();
    test_sparse_identity_keeps_ieee_zero_history();
    test_silence_music_and_margins();
    test_seek_and_sparse_channel_guard();
    puts("BStream portable audio DSP: all 9 test groups passed");
    return 0;
}
