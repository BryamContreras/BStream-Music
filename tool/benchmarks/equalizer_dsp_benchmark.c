/* Build against the shipping portable DSP. No benchmark logic enters the app.
 * Example (Android NDK, run the executable with app_process-independent shell):
 * clang --target=x86_64-linux-android24 -std=c11 -O3 -DNDEBUG \
 *   -Ithird_party/just_audio/darwin/just_audio/Sources/just_audio/include/just_audio \
 *   tool/benchmarks/equalizer_dsp_benchmark.c \
 *   third_party/just_audio/darwin/just_audio/Sources/just_audio/BStreamAudioDSP.c \
 *   -lm -o equalizer-dsp-benchmark
 * Optional first argument: text file, one curve per line: name g0 ... g9.
 * Optional second argument: run label, e.g. baseline or optimized.
 * p95 describes repeated batches normalized per block, not individual callbacks.
 */
#define _POSIX_C_SOURCE 200809L
#include "BStreamAudioDSP.h"

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CHANNELS 2u
#define BLOCKS 128u
#define REPETITIONS 7u
#define MAX_CURVES 96u
#define PI 3.14159265358979323846264338327950288

typedef struct {
    char name[80];
    bool enabled;
    double gains[BSTREAM_DSP_BANDS];
} Curve;

static volatile uint64_t observed_checksum;
static const char *run_label = "unspecified";

static uint64_t nanos(clockid_t clock) {
    struct timespec value;
    if (clock_gettime(clock, &value) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static int compare_double(const void *left, const void *right) {
    const double a = *(const double *)left, b = *(const double *)right;
    return (a > b) - (a < b);
}

static double percentile(double values[REPETITIONS], double percentile_value) {
    double sorted[REPETITIONS];
    memcpy(sorted, values, sizeof(sorted));
    qsort(sorted, REPETITIONS, sizeof(*sorted), compare_double);
    size_t index = (size_t)ceil(percentile_value * REPETITIONS) - 1;
    if (index >= REPETITIONS) index = REPETITIONS - 1;
    return sorted[index];
}

static uint64_t checksum(const void *buffer, size_t bytes) {
    const unsigned char *values = (const unsigned char *)buffer;
    uint64_t result = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < bytes; ++i) {
        result ^= values[i];
        result *= UINT64_C(1099511628211);
    }
    observed_checksum ^= result;
    return result;
}

static unsigned base_curves(Curve curves[MAX_CURVES]) {
    unsigned count = 0;
    curves[count++] = (Curve){.name = "off", .enabled = false};
    curves[count++] = (Curve){.name = "flat", .enabled = true};
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
        for (int sign = -1; sign <= 1; sign += 2) {
            Curve *curve = &curves[count++];
            curve->enabled = true;
            curve->gains[band] = sign * 6;
            snprintf(curve->name, sizeof(curve->name), "band_%u_%s6",
                     band, sign > 0 ? "plus" : "minus");
        }
    }
    curves[count] = (Curve){.name = "all_plus6", .enabled = true};
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) curves[count].gains[band] = 6;
    ++count;
    curves[count] = (Curve){.name = "all_minus6", .enabled = true};
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) curves[count].gains[band] = -6;
    ++count;
    curves[count] = (Curve){.name = "alternating12", .enabled = true};
    for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band)
        curves[count].gains[band] = band % 2 ? -12 : 12;
    return count + 1;
}

static unsigned read_curves(const char *path, Curve curves[MAX_CURVES], unsigned count) {
    FILE *file = fopen(path, "r");
    if (!file) { perror(path); exit(2); }
    char line[512];
    while (fgets(line, sizeof(line), file)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        if (count >= MAX_CURVES) { fprintf(stderr, "Too many curves\n"); exit(2); }
        Curve *curve = &curves[count];
        curve->enabled = true;
        const int fields = sscanf(line, "%79s %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf",
            curve->name, &curve->gains[0], &curve->gains[1], &curve->gains[2],
            &curve->gains[3], &curve->gains[4], &curve->gains[5], &curve->gains[6],
            &curve->gains[7], &curve->gains[8], &curve->gains[9]);
        if (fields != 11) { fprintf(stderr, "Invalid curve: %s", line); exit(2); }
        for (unsigned band = 0; band < BSTREAM_DSP_BANDS; ++band) {
            if (!isfinite(curve->gains[band]) || fabs(curve->gains[band]) > 12) {
                fprintf(stderr, "Invalid gain in %s\n", curve->name); exit(2);
            }
        }
        ++count;
    }
    fclose(file);
    return count;
}

static void generate_input(void *target, unsigned rate, unsigned frames, bool pcm16) {
    uint32_t random = UINT32_C(0x3456789a);
    for (size_t frame = 0; frame < (size_t)frames * BLOCKS; ++frame) {
        for (unsigned channel = 0; channel < CHANNELS; ++channel) {
            random = random * UINT32_C(1664525) + UINT32_C(1013904223);
            const double noise = ((random >> 8) / 16777216.0 - .5) * .012;
            const double time = (double)frame / rate;
            const double sample = noise + .02 * sin(2 * PI * 73 * time + channel * .7)
                + .02 * sin(2 * PI * 1031 * time + channel * .3)
                + .02 * sin(2 * PI * 7193 * time + channel * .4);
            const size_t i = frame * CHANNELS + channel;
            if (pcm16) ((int16_t *)target)[i] = (int16_t)round(sample * 32768);
            else ((float *)target)[i] = (float)sample;
        }
    }
}

static void process_blocks(BStreamDSP *dsp, void *pool, unsigned frames, bool pcm16) {
    const size_t stride = frames * CHANNELS * (pcm16 ? sizeof(int16_t) : sizeof(float));
    for (unsigned block = 0; block < BLOCKS; ++block) {
        void *buffers[] = {(unsigned char *)pool + block * stride};
        if (pcm16) BStreamDSPProcessInt16(dsp, buffers, frames, true);
        else BStreamDSPProcessFloat32(dsp, buffers, frames, true);
    }
}

static void measure(const Curve *curve, unsigned rate, bool pcm16, bool transition) {
    const unsigned frames = rate / 100;
    const size_t bytes = (size_t)frames * BLOCKS * CHANNELS *
        (pcm16 ? sizeof(int16_t) : sizeof(float));
    void *input = malloc(bytes), *pool = malloc(bytes);
    if (!input || !pool) { fprintf(stderr, "Allocation failed\n"); exit(2); }
    generate_input(input, rate, frames, pcm16);
    double cpu[REPETITIONS], wall[REPETITIONS], configure[REPETITIONS];
    uint64_t reference_hash = 0;
    bool byte_exact = true, bypass_checked = false, configured = true;
    for (unsigned repetition = 0; repetition < REPETITIONS + 2; ++repetition) {
        BStreamDSP *dsp = BStreamDSPCreate(rate, CHANNELS);
        if (!dsp) exit(2);
        const uint64_t configure_start = nanos(CLOCK_THREAD_CPUTIME_ID);
        configured &= BStreamDSPSetEqualizer(dsp, curve->enabled, curve->gains,
                                            repetition + 1, !transition);
        const uint64_t configure_end = nanos(CLOCK_THREAD_CPUTIME_ID);
        memcpy(pool, input, bytes);
        const uint64_t cpu_start = nanos(CLOCK_THREAD_CPUTIME_ID);
        const uint64_t wall_start = nanos(CLOCK_MONOTONIC);
        process_blocks(dsp, pool, frames, pcm16);
        const uint64_t wall_end = nanos(CLOCK_MONOTONIC);
        const uint64_t cpu_end = nanos(CLOCK_THREAD_CPUTIME_ID);
        const uint64_t hash = checksum(pool, bytes);
        if (repetition >= 2) {
            const unsigned index = repetition - 2;
            const double seconds = (double)(frames * BLOCKS) / rate;
            cpu[index] = (cpu_end - cpu_start) / 1e6 / seconds;
            wall[index] = (wall_end - wall_start) / 1e3 / BLOCKS;
            configure[index] = (configure_end - configure_start) / 1e3;
            if (index == 0) reference_hash = hash;
            else if (hash != reference_hash) { fprintf(stderr, "Non-deterministic output\n"); exit(2); }
        }
        if (!curve->enabled || !BStreamDSPGetStatus(dsp).enabled) {
            bypass_checked = true;
            byte_exact &= memcmp(pool, input, bytes) == 0;
        }
        const BStreamDSPStatus status = BStreamDSPGetStatus(dsp);
        if (!configured || status.processedFrames != (uint64_t)frames * BLOCKS ||
            status.appliedRevision != repetition + 1) {
            fprintf(stderr, "Incomplete DSP state for %s\n", curve->name); exit(2);
        }
        BStreamDSPDestroy(dsp);
    }
    printf("{\"engine\":\"portable-c\",\"run\":\"%s\",\"case\":\"%s%s\","
           "\"rate\":%u,\"channels\":%u,\"format\":\"%s\",\"frames_per_block\":%u,"
           "\"repetitions\":%u,\"blocks_per_repetition\":%u,"
           "\"cpu_ms_per_audio_second_median\":%.9f,\"cpu_ms_per_audio_second_p95\":%.9f,"
           "\"wall_us_per_block_batch_median\":%.9f,\"wall_us_per_block_batch_p95\":%.9f,"
           "\"configure_cpu_us_median\":%.9f,\"configure_cpu_us_p95\":%.9f,"
           "\"output_hash\":\"%016" PRIx64 "\",\"bypass_byte_exact\":%s}\n",
           run_label, curve->name, transition ? "_transition" : "", rate, CHANNELS,
           pcm16 ? "s16" : "f32", frames, REPETITIONS, BLOCKS,
           percentile(cpu, .5), percentile(cpu, .95), percentile(wall, .5),
           percentile(wall, .95), percentile(configure, .5), percentile(configure, .95),
           reference_hash, bypass_checked ? (byte_exact ? "true" : "false") : "null");
    fflush(stdout);
    free(input);
    free(pool);
}

int main(int argc, char **argv) {
    Curve curves[MAX_CURVES] = {0};
    unsigned count = base_curves(curves);
    if (argc > 1 && strcmp(argv[1], "-") != 0) count = read_curves(argv[1], curves, count);
    if (argc > 2) run_label = argv[2];
    for (unsigned rate_index = 0; rate_index < 2; ++rate_index) {
        const unsigned rate = rate_index ? 96000 : 48000;
        for (unsigned type = 0; type < 2; ++type) {
            for (unsigned curve = 0; curve < count; ++curve) measure(&curves[curve], rate, type != 0, false);
            measure(&curves[22], rate, type != 0, true);
        }
    }
    fprintf(stderr, "Observed checksum: %016" PRIx64 "\n", observed_checksum);
    return 0;
}
