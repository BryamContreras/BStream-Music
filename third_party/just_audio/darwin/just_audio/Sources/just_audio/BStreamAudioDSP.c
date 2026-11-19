#include "include/just_audio/BStreamAudioDSP.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define BSTREAM_PI 3.14159265358979323846264338327950288
#define BSTREAM_SILENCE_EVENTS 64
#define BSTREAM_SMOOTH_WINDOWS 10

const double BStreamDSPFrequencies[BSTREAM_DSP_BANDS] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};

struct BStreamDSP {
    double rate;
    uint32_t channels;
    bool enabled;
    bool active;
    bool bypass;
    double gains[BSTREAM_DSP_BANDS];
    double coefficients[BSTREAM_DSP_BANDS][5];
    double target[BSTREAM_DSP_BANDS][5];
    double step[BSTREAM_DSP_BANDS][5];
    double z1[BSTREAM_DSP_BANDS][BSTREAM_DSP_MAX_CHANNELS];
    double z2[BSTREAM_DSP_BANDS][BSTREAM_DSP_MAX_CHANNELS];
    double preampDb;
    double preamp;
    double targetPreamp;
    double preampStep;
    unsigned targetBandCount;
    uint64_t transitionFrames;
    uint64_t processedFrames;
    uint64_t revision;
    uint64_t appliedRevision;
};

typedef enum { bs_f32, bs_f64, bs_i16, bs_i32 } BStreamPCMType;

static bool valid_format(double rate, uint32_t channels) {
    return isfinite(rate) && rate >= 1000 && rate <= 768000 &&
        channels > 0 && channels <= BSTREAM_DSP_MAX_CHANNELS;
}

static double bounded(double value, double minimum, double maximum) {
    return value < minimum ? minimum : value > maximum ? maximum : value;
}

static void identity(double coefficients[BSTREAM_DSP_BANDS][5]) {
    memset(coefficients, 0, sizeof(double) * BSTREAM_DSP_BANDS * 5);
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) coefficients[band][0] = 1;
}

BStreamDSP *BStreamDSPCreate(double sampleRate, uint32_t channels) {
    if (!valid_format(sampleRate, channels)) return NULL;
    BStreamDSP *dsp = (BStreamDSP *)calloc(1, sizeof(BStreamDSP));
    if (!dsp) return NULL;
    dsp->rate = sampleRate;
    dsp->channels = channels;
    dsp->bypass = true;
    dsp->preamp = dsp->targetPreamp = 1;
    dsp->appliedRevision = UINT64_MAX;
    identity(dsp->coefficients);
    identity(dsp->target);
    return dsp;
}

void BStreamDSPDestroy(BStreamDSP *dsp) { free(dsp); }

double BStreamDSPHeadroomDb(const double gainsDb[BSTREAM_DSP_BANDS]) {
    double total = 0;
    unsigned boosts = 0;
    double amplitudeSquared[BSTREAM_DSP_BANDS] = {0};
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
        if (gainsDb[band] < .01) continue;
        total += gainsDb[band];
        ++boosts;
        amplitudeSquared[band] = pow(10, gainsDb[band] / 20);
    }
    if (boosts < 2) return -total;
    double maximum = 0;
    const double start = log(BStreamDSPFrequencies[0]);
    const double range = log(BStreamDSPFrequencies[BSTREAM_DSP_BANDS - 1]) - start;
    for (unsigned point = 0; point <= 256 + BSTREAM_DSP_BANDS; ++point) {
        const double frequency = point <= 256
            ? exp(start + range * point / 256.0) : BStreamDSPFrequencies[point - 257];
        double response = 0;
        for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
            const double a2 = amplitudeSquared[band];
            if (a2 == 0) continue;
            const double ratio = frequency / BStreamDSPFrequencies[band];
            const double r2 = ratio * ratio;
            const double difference = 1 - r2;
            const double d = difference * difference;
            response += 10 * log10((d + r2 * a2) / (d + r2 / a2));
        }
        maximum = fmax(maximum, response);
    }
    return -fmin(total, maximum + .1);
}

bool BStreamDSPSetEqualizer(BStreamDSP *dsp, bool enabled, const double gainsDb[BSTREAM_DSP_BANDS],
                          uint64_t revision, bool immediate) {
    if (!dsp || !gainsDb) return false;
    double gains[BSTREAM_DSP_BANDS];
    bool active = false;
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
        if (!isfinite(gainsDb[band])) return false;
        gains[band] = bounded(gainsDb[band], -12, 12);
        if (fabs(gains[band]) >= 0.01) active = true;
    }
    active = active && enabled;
    bool changed = dsp->enabled != enabled || memcmp(dsp->gains, gains, sizeof(gains)) != 0;
    dsp->revision = revision;
    if (!changed && !immediate) {
        if (!dsp->transitionFrames && dsp->processedFrames) dsp->appliedRevision = revision;
        return true;
    }
    dsp->enabled = enabled;
    dsp->active = active;
    memcpy(dsp->gains, gains, sizeof(gains));
    dsp->preampDb = active ? BStreamDSPHeadroomDb(gains) : 0;
    dsp->targetPreamp = active ? pow(10, dsp->preampDb / 20) : 1;
    /* Two bypass configurations need no transition through sample arithmetic. */
    if (!active && dsp->bypass) immediate = true;
    identity(dsp->target);
    dsp->targetBandCount = 0;
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
        const double frequency = BStreamDSPFrequencies[band];
        const double gain = active ? gains[band] : 0;
        if (frequency >= dsp->rate * .5 || fabs(gain) < .01) continue;
        ++dsp->targetBandCount;
        const double amplitude = pow(10, gain / 40);
        const double omega = 2 * BSTREAM_PI * frequency / dsp->rate;
        const double alpha = sin(omega) / 2; /* peaking Q=1 */
        const double cosine = cos(omega);
        const double a0 = 1 + alpha / amplitude;
        dsp->target[band][0] = (1 + alpha * amplitude) / a0;
        dsp->target[band][1] = -2 * cosine / a0;
        dsp->target[band][2] = (1 - alpha * amplitude) / a0;
        dsp->target[band][3] = -2 * cosine / a0;
        dsp->target[band][4] = (1 - alpha / amplitude) / a0;
    }
    if (immediate) {
        memcpy(dsp->coefficients, dsp->target, sizeof(dsp->target));
        dsp->preamp = dsp->targetPreamp;
        dsp->bypass = !active;
        dsp->transitionFrames = 0;
    } else {
        dsp->transitionFrames = (uint64_t)fmax(1, floor(dsp->rate * .025));
        for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band)
            for (unsigned c = 0; c < 5; ++c)
                dsp->step[band][c] = (dsp->target[band][c] - dsp->coefficients[band][c]) /
                    (double)dsp->transitionFrames;
        dsp->preampStep = (dsp->targetPreamp - dsp->preamp) / (double)dsp->transitionFrames;
        dsp->bypass = false;
    }
    dsp->appliedRevision = UINT64_MAX;
    return true;
}

void BStreamDSPReset(BStreamDSP *dsp) {
    if (!dsp) return;
    memset(dsp->z1, 0, sizeof(dsp->z1));
    memset(dsp->z2, 0, sizeof(dsp->z2));
    memcpy(dsp->coefficients, dsp->target, sizeof(dsp->target));
    dsp->preamp = dsp->targetPreamp;
    dsp->bypass = !dsp->active;
    dsp->transitionFrames = 0;
    dsp->appliedRevision = UINT64_MAX;
}

BStreamDSPStatus BStreamDSPGetStatus(const BStreamDSP *dsp) {
    BStreamDSPStatus status = {0};
    status.appliedRevision = UINT64_MAX;
    if (!dsp) return status;
    status.enabled = dsp->active;
    status.preampDb = dsp->preampDb;
    status.sampleRate = dsp->rate;
    status.channels = dsp->channels;
    status.processedFrames = dsp->processedFrames;
    status.revision = dsp->revision;
    status.appliedRevision = dsp->appliedRevision;
    return status;
}

bool BStreamDSPIsBypassed(const BStreamDSP *dsp) { return !dsp || dsp->bypass; }

static double read_sample(const void *buffer, size_t sample, BStreamPCMType type) {
    switch (type) {
        case bs_f32: return ((const float *)buffer)[sample];
        case bs_f64: return ((const double *)buffer)[sample];
        case bs_i16: return ((const int16_t *)buffer)[sample] / 32768.0;
        case bs_i32: return ((const int32_t *)buffer)[sample] / 2147483648.0;
    }
    return 0;
}

static void write_sample(void *buffer, size_t index, BStreamPCMType type, double sample) {
    if (!isfinite(sample)) sample = 0;
    sample = bounded(sample, -1, 1);
    switch (type) {
        case bs_f32: ((float *)buffer)[index] = (float)sample; break;
        case bs_f64: ((double *)buffer)[index] = sample; break;
        case bs_i16:
            ((int16_t *)buffer)[index] = (int16_t)bounded(round(sample * 32768), -32768, 32767);
            break;
        case bs_i32:
            ((int32_t *)buffer)[index] = (int32_t)bounded(round(sample * 2147483648.0),
                                                       -2147483648.0, 2147483647.0);
            break;
    }
}

static bool valid_buffers(const void *const buffers[], uint32_t channels, bool interleaved) {
    if (!buffers) return false;
    for (uint32_t channel = 0; channel < (interleaved ? 1 : channels); ++channel)
        if (!buffers[channel]) return false;
    return true;
}

/* Neutral sections do not need sample arithmetic once both delay elements have
 * drained. Keep all sections during a glide, and retain identity sections with
 * history for the entire block: retiring them early would discard their tail.
 * The bounded scan is performed once per stable block, never per sample. */
static unsigned processing_bands(const BStreamDSP *dsp, unsigned bands[BSTREAM_DSP_BANDS]) {
    unsigned count = 0;
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
        const double *c = dsp->coefficients[band];
        bool required = c[0] != 1;
        for (unsigned i = 1; !required && i < 5; ++i)
            required = c[i] != 0 || signbit(c[i]);
        for (uint32_t channel = 0; !required && channel < dsp->channels; ++channel)
            required = dsp->z1[band][channel] != 0 || signbit(dsp->z1[band][channel]) ||
                dsp->z2[band][channel] != 0 || signbit(dsp->z2[band][channel]);
        if (required) bands[count++] = band;
    }
    return count;
}

static inline double filter_band(BStreamDSP *dsp, unsigned band, uint32_t channel, double sample) {
    const double *c = dsp->coefficients[band];
    const double filtered = c[0] * sample + dsp->z1[band][channel];
    dsp->z1[band][channel] = c[1] * sample - c[3] * filtered + dsp->z2[band][channel];
    dsp->z2[band][channel] = c[2] * sample - c[4] * filtered;
    return filtered;
}

static void process_dense_original(BStreamDSP *dsp, void *const buffers[], size_t frames,
                    bool interleaved, BStreamPCMType type) {
    if (!dsp || !frames || !valid_buffers((const void *const *)buffers, dsp->channels, interleaved)) return;
    if (!dsp->bypass) {
        for (size_t frame = 0; frame < frames; ++frame) {
            if (dsp->transitionFrames) {
                for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band)
                    for (unsigned c = 0; c < 5; ++c)
                        dsp->coefficients[band][c] += dsp->step[band][c];
                dsp->preamp += dsp->preampStep;
                if (!--dsp->transitionFrames) {
                    memcpy(dsp->coefficients, dsp->target, sizeof(dsp->target));
                    dsp->preamp = dsp->targetPreamp;
                    dsp->bypass = !dsp->active;
                    if (dsp->bypass) {
                        memset(dsp->z1, 0, sizeof(dsp->z1));
                        memset(dsp->z2, 0, sizeof(dsp->z2));
                    }
                }
            }
            /* Remaining samples are left byte-exact after the glide ends. */
            if (dsp->bypass) break;
            for (uint32_t channel = 0; channel < dsp->channels; ++channel) {
                void *buffer = buffers[interleaved ? 0 : channel];
                const size_t index = interleaved ? frame * dsp->channels + channel : frame;
                double sample = read_sample(buffer, index, type);
                if (!isfinite(sample)) sample = 0;
                sample *= dsp->preamp;
                for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
                    const double *c = dsp->coefficients[band];
                    const double filtered = c[0] * sample + dsp->z1[band][channel];
                    dsp->z1[band][channel] = c[1] * sample - c[3] * filtered + dsp->z2[band][channel];
                    dsp->z2[band][channel] = c[2] * sample - c[4] * filtered;
                    sample = filtered;
                }
                write_sample(buffer, index, type, sample);
            }
        }
    }
    dsp->processedFrames += frames;
    dsp->appliedRevision = dsp->transitionFrames ? UINT64_MAX : dsp->revision;
}

/* The stable sparse path has no glide bookkeeping inside its sample loop.
 * A negative-zero/non-finite exception rejoins the dense sequence for the
 * current tail and the remainder of this block, preserving IEEE history. */
static void process_sparse(BStreamDSP *dsp, void *const buffers[], size_t frames,
                           bool interleaved, BStreamPCMType type,
                           const unsigned bands[BSTREAM_DSP_BANDS], unsigned count) {
    bool denseRemainder = false;
    for (size_t frame = 0; frame < frames; ++frame) {
        for (uint32_t channel = 0; channel < dsp->channels; ++channel) {
            void *buffer = buffers[interleaved ? 0 : channel];
            const size_t index = interleaved ? frame * dsp->channels + channel : frame;
            double sample = read_sample(buffer, index, type);
            if (!isfinite(sample)) sample = 0;
            sample *= dsp->preamp;
            if (denseRemainder) {
                for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band)
                    sample = filter_band(dsp, band, channel, sample);
            } else {
                unsigned first = 0;
                for (unsigned i = 0; i < count; ++i) {
                    if (bands[i] > first && ((sample == 0 && signbit(sample)) || !isfinite(sample))) {
                        for (unsigned band = first; band < BSTREAM_DSP_BANDS; ++band)
                            sample = filter_band(dsp, band, channel, sample);
                        denseRemainder = true;
                        first = BSTREAM_DSP_BANDS;
                        break;
                    }
                    sample = filter_band(dsp, bands[i], channel, sample);
                    first = bands[i] + 1;
                }
                if (first < BSTREAM_DSP_BANDS && ((sample == 0 && signbit(sample)) || !isfinite(sample))) {
                    for (unsigned band = first; band < BSTREAM_DSP_BANDS; ++band)
                        sample = filter_band(dsp, band, channel, sample);
                    denseRemainder = true;
                }
            }
            write_sample(buffer, index, type, sample);
        }
    }
    dsp->processedFrames += frames;
    dsp->appliedRevision = dsp->revision;
}

/* Select once per block. Full curves, glides, bypass and invalid buffers retain
 * the original dense kernel and its compiler specialization decisions. */
static void process(BStreamDSP *dsp, void *const buffers[], size_t frames,
                    bool interleaved, BStreamPCMType type) {
    if (dsp && frames && !dsp->bypass && !dsp->transitionFrames && dsp->targetBandCount < 7 &&
        valid_buffers((const void *const *)buffers, dsp->channels, interleaved)) {
        unsigned bands[BSTREAM_DSP_BANDS];
        const unsigned count = processing_bands(dsp, bands);
        if (count < 7) {
            process_sparse(dsp, buffers, frames, interleaved, type, bands, count);
            return;
        }
    }
    process_dense_original(dsp, buffers, frames, interleaved, type);
}
#define DSP_PROCESS_FUNCTION(NAME, TYPE) \
    void NAME(BStreamDSP *dsp, void *const buffers[], size_t frames, bool interleaved) { \
        process(dsp, buffers, frames, interleaved, TYPE); \
    }
DSP_PROCESS_FUNCTION(BStreamDSPProcessFloat32, bs_f32)
DSP_PROCESS_FUNCTION(BStreamDSPProcessFloat64, bs_f64)
DSP_PROCESS_FUNCTION(BStreamDSPProcessInt16, bs_i16)
DSP_PROCESS_FUNCTION(BStreamDSPProcessInt32, bs_i32)

struct BStreamSilence {
    double rate;
    uint32_t channels;
    uint32_t windowFrames, hopFrames, contextFrames;
    uint64_t edgeMinimumFrames, internalMinimumFrames, leadingFrames, trailingFrames;
    double *framePowers;
    uint32_t frameRingIndex, frameRingSize, guardedFrames;
    double framePowerSum;
    double windowPowers[BSTREAM_SMOOTH_WINDOWS];
    uint32_t windowRingIndex, windowRingSize;
    double windowPowerSum;
    uint64_t originFrame, cursorFrame, lastProtectedFrame;
    bool candidateActive, candidateConfirmed, candidateIsIntro;
    uint64_t candidateStart, firstProtectedInCandidate;
    uint64_t candidateWindows, silentWindows, consecutiveSilent, longestSilent;
    uint32_t inactiveHysteresis;
    BStreamSilenceInterval intervals[BSTREAM_SILENCE_EVENTS];
    uint32_t eventHead, eventCount;
    uint64_t droppedIntervals;
};

static uint64_t frames_for(double rate, double seconds) { return (uint64_t)fmax(1, floor(rate * seconds)); }

BStreamSilence *BStreamSilenceCreate(double sampleRate, uint32_t channels, bool initialEdge) {
    if (!valid_format(sampleRate, channels)) return NULL;
    BStreamSilence *silence = (BStreamSilence *)calloc(1, sizeof(BStreamSilence));
    if (!silence) return NULL;
    silence->rate = sampleRate;
    silence->channels = channels;
    silence->windowFrames = (uint32_t)frames_for(sampleRate, .1);
    silence->hopFrames = (uint32_t)frames_for(sampleRate, .025);
    silence->contextFrames = silence->windowFrames + 9 * silence->hopFrames;
    silence->edgeMinimumFrames = frames_for(sampleRate, 1.8);
    silence->internalMinimumFrames = frames_for(sampleRate, 4.5);
    silence->leadingFrames = frames_for(sampleRate, .15);
    silence->trailingFrames = frames_for(sampleRate, .25);
    silence->framePowers = (double *)calloc(silence->windowFrames, sizeof(double));
    if (!silence->framePowers) { free(silence); return NULL; }
    BStreamSilenceReset(silence, 0, initialEdge);
    return silence;
}

void BStreamSilenceDestroy(BStreamSilence *silence) {
    if (!silence) return;
    free(silence->framePowers);
    free(silence);
}

static void start_candidate(BStreamSilence *silence, uint64_t start, bool initialEdge) {
    silence->candidateActive = true;
    silence->candidateConfirmed = false;
    silence->candidateIsIntro = initialEdge;
    silence->candidateStart = start;
    silence->firstProtectedInCandidate = UINT64_MAX;
    silence->candidateWindows = silence->silentWindows = 0;
    silence->consecutiveSilent = silence->longestSilent = 0;
}

void BStreamSilenceReset(BStreamSilence *silence, uint64_t startFrame, bool initialEdge) {
    if (!silence) return;
    memset(silence->framePowers, 0, silence->windowFrames * sizeof(double));
    memset(silence->windowPowers, 0, sizeof(silence->windowPowers));
    silence->frameRingIndex = silence->frameRingSize = silence->guardedFrames = 0;
    silence->framePowerSum = silence->windowPowerSum = 0;
    silence->windowRingIndex = silence->windowRingSize = 0;
    silence->originFrame = silence->cursorFrame = silence->lastProtectedFrame = startFrame;
    silence->candidateActive = silence->candidateConfirmed = false;
    silence->inactiveHysteresis = silence->eventHead = silence->eventCount = 0;
    silence->droppedIntervals = 0;
    if (initialEdge) start_candidate(silence, startFrame, true);
}

static uint64_t candidate_end(const BStreamSilence *silence) {
    return silence->firstProtectedInCandidate < silence->cursorFrame
        ? silence->firstProtectedInCandidate : silence->cursorFrame;
}

static bool candidate_qualifies(const BStreamSilence *silence) {
    uint64_t minimum = silence->candidateIsIntro
        ? silence->edgeMinimumFrames : silence->internalMinimumFrames;
    uint64_t end = candidate_end(silence);
    return end >= silence->candidateStart && end - silence->candidateStart >= minimum &&
        silence->candidateWindows && silence->silentWindows * 100 >= silence->candidateWindows * 90 &&
        silence->longestSilent >= 32; /* uninterrupted 800 ms of 25 ms votes */
}

static void publish_interval(BStreamSilence *silence) {
    uint64_t start = silence->candidateStart + silence->leadingFrames;
    uint64_t candidateEnd = candidate_end(silence);
    if (candidateEnd < silence->trailingFrames) return;
    uint64_t end = candidateEnd - silence->trailingFrames;
    if (end <= start) return;
    if (silence->eventCount) {
        unsigned last = (silence->eventHead + silence->eventCount - 1) % BSTREAM_SILENCE_EVENTS;
        if (silence->intervals[last].startFrame == start) {
            if (end > silence->intervals[last].endFrame) silence->intervals[last].endFrame = end;
            return;
        }
    }
    if (silence->eventCount == BSTREAM_SILENCE_EVENTS) {
        /* A bounded analyzer that neglects to drain events loses opportunities,
         * never audio: it simply leaves these later silence ranges unskipped. */
        ++silence->droppedIntervals;
        return;
    }
    unsigned index = (silence->eventHead + silence->eventCount++) % BSTREAM_SILENCE_EVENTS;
    silence->intervals[index].startFrame = start;
    silence->intervals[index].endFrame = end;
}

enum { envelope_pending, envelope_silent, envelope_hysteresis, envelope_noisy, envelope_peak };

static int analyze_power(BStreamSilence *silence, double power) {
    const double peakPower = (64.0 / 32768.0) * (64.0 / 32768.0);
    if (silence->frameRingSize == silence->windowFrames) {
        double previous = silence->framePowers[silence->frameRingIndex];
        silence->framePowerSum -= previous;
        if (previous > peakPower) --silence->guardedFrames;
    } else ++silence->frameRingSize;
    silence->framePowers[silence->frameRingIndex] = power;
    silence->framePowerSum += power;
    if (power > peakPower) {
        ++silence->guardedFrames;
        silence->lastProtectedFrame = silence->cursorFrame + 1;
        if (silence->candidateActive && silence->firstProtectedInCandidate == UINT64_MAX)
            silence->firstProtectedInCandidate = silence->cursorFrame;
    }
    silence->frameRingIndex = (silence->frameRingIndex + 1) % silence->windowFrames;
    ++silence->cursorFrame;
    uint64_t count = silence->cursorFrame - silence->originFrame;
    if (silence->frameRingSize < silence->windowFrames ||
        (count - silence->windowFrames) % silence->hopFrames) return envelope_pending;

    double windowPower = silence->framePowerSum / silence->windowFrames;
    if (silence->windowRingSize == BSTREAM_SMOOTH_WINDOWS)
        silence->windowPowerSum -= silence->windowPowers[silence->windowRingIndex];
    else ++silence->windowRingSize;
    silence->windowPowers[silence->windowRingIndex] = windowPower;
    silence->windowPowerSum += windowPower;
    silence->windowRingIndex = (silence->windowRingIndex + 1) % BSTREAM_SMOOTH_WINDOWS;
    double smoothed = fmax(0, silence->windowPowerSum / silence->windowRingSize);
    if (smoothed >= 0.00002511886431509582) return envelope_noisy; /* -46 dBFS */
    if (smoothed <= 0.00000630957344480193) /* -52 dBFS */
        return silence->guardedFrames ? envelope_peak : envelope_silent;
    return envelope_hysteresis;
}

static void handle_envelope(BStreamSilence *silence, int envelope) {
    if (envelope == envelope_pending) return;
    /* A confirmed gap must finish at fresh raw musical evidence even if its
     * smoothed envelope stays in hysteresis. Otherwise the protected end cap
     * could freeze that candidate forever and hide later independent gaps. */
    if (silence->candidateActive && silence->candidateConfirmed &&
        silence->firstProtectedInCandidate != UINT64_MAX) {
        publish_interval(silence);
        silence->candidateActive = silence->candidateConfirmed = false;
    }
    if (envelope == envelope_noisy || envelope == envelope_peak) {
        if (silence->candidateActive && silence->candidateConfirmed) publish_interval(silence);
        silence->candidateActive = silence->candidateConfirmed = false;
        silence->inactiveHysteresis = 0;
        return;
    }
    if (!silence->candidateActive) {
        if (envelope == envelope_silent) {
            uint64_t contextStart = silence->cursorFrame - silence->originFrame > silence->contextFrames
                ? silence->cursorFrame - silence->contextFrames : silence->originFrame;
            uint64_t start = contextStart > silence->lastProtectedFrame
                ? contextStart : silence->lastProtectedFrame;
            uint32_t preceding = silence->inactiveHysteresis;
            start_candidate(silence, start, false);
            silence->candidateWindows = preceding;
            silence->inactiveHysteresis = 0;
        } else {
            uint32_t contextWindows = (silence->contextFrames + silence->hopFrames - 1) / silence->hopFrames;
            if (silence->inactiveHysteresis < contextWindows) ++silence->inactiveHysteresis;
            return;
        }
    }
    ++silence->candidateWindows;
    if (envelope == envelope_silent) {
        ++silence->silentWindows;
        if (++silence->consecutiveSilent > silence->longestSilent)
            silence->longestSilent = silence->consecutiveSilent;
    } else silence->consecutiveSilent = 0;

    if (silence->candidateConfirmed || candidate_qualifies(silence)) {
        silence->candidateConfirmed = true;
        publish_interval(silence);
        return;
    }
    uint64_t minimum = silence->candidateIsIntro
        ? silence->edgeMinimumFrames : silence->internalMinimumFrames;
    uint64_t end = candidate_end(silence);
    uint64_t length = end >= silence->candidateStart ? end - silence->candidateStart : 0;
    uint64_t remaining = length < minimum ? minimum - length : 0;
    uint64_t windows = (remaining + silence->hopFrames - 1) / silence->hopFrames;
    if (!remaining || (silence->silentWindows + windows) * 100 <
        (silence->candidateWindows + windows) * 90) {
        silence->candidateActive = silence->candidateConfirmed = false;
    }
}

static void analyze(BStreamSilence *silence, const void *const buffers[], size_t frames,
                    bool interleaved, BStreamPCMType type) {
    if (!silence || !valid_buffers(buffers, silence->channels, interleaved)) return;
    for (size_t frame = 0; frame < frames; ++frame) {
        double maximumPower = 0;
        for (uint32_t channel = 0; channel < silence->channels; ++channel) {
            const void *buffer = buffers[interleaved ? 0 : channel];
            size_t index = interleaved ? frame * silence->channels + channel : frame;
            double sample = read_sample(buffer, index, type);
            if (!isfinite(sample)) sample = 1; /* Never classify invalid PCM as silence. */
            double power = fmin(1, sample * sample);
            if (power > maximumPower) maximumPower = power;
        }
        handle_envelope(silence, analyze_power(silence, maximumPower));
    }
}

#define SILENCE_PROCESS_FUNCTION(NAME, TYPE) \
    void NAME(BStreamSilence *silence, const void *const buffers[], size_t frames, bool interleaved) { \
        analyze(silence, buffers, frames, interleaved, TYPE); \
    }
SILENCE_PROCESS_FUNCTION(BStreamSilenceProcessFloat32, bs_f32)
SILENCE_PROCESS_FUNCTION(BStreamSilenceProcessFloat64, bs_f64)
SILENCE_PROCESS_FUNCTION(BStreamSilenceProcessInt16, bs_i16)
SILENCE_PROCESS_FUNCTION(BStreamSilenceProcessInt32, bs_i32)

void BStreamSilenceFinish(BStreamSilence *silence) {
    if (!silence) return;
    if (silence->candidateActive && (silence->candidateConfirmed || candidate_qualifies(silence)))
        publish_interval(silence);
    silence->candidateActive = silence->candidateConfirmed = false;
}

bool BStreamSilencePopInterval(BStreamSilence *silence, BStreamSilenceInterval *interval) {
    if (!silence || !interval || !silence->eventCount) return false;
    *interval = silence->intervals[silence->eventHead];
    silence->eventHead = (silence->eventHead + 1) % BSTREAM_SILENCE_EVENTS;
    --silence->eventCount;
    return true;
}

uint64_t BStreamSilenceAnalyzedFrames(const BStreamSilence *silence) {
    return silence ? silence->cursorFrame : 0;
}
uint64_t BStreamSilenceDroppedIntervals(const BStreamSilence *silence) {
    return silence ? silence->droppedIntervals : 0;
}
