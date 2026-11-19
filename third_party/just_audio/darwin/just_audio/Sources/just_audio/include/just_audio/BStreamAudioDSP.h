#ifndef BSTREAM_AUDIO_DSP_H
#define BSTREAM_AUDIO_DSP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BSTREAM_DSP_BANDS 10
#define BSTREAM_DSP_MAX_CHANNELS 8

typedef struct BStreamDSP BStreamDSP;
typedef struct {
    bool enabled;
    double preampDb;
    double sampleRate;
    uint32_t channels;
    uint64_t processedFrames;
    uint64_t revision;
    /* UINT64_MAX while a transition is outstanding or no frames were processed. */
    uint64_t appliedRevision;
} BStreamDSPStatus;

extern const double BStreamDSPFrequencies[BSTREAM_DSP_BANDS];

/* Estimate combined positive-band headroom once per parameter snapshot.
 * Inputs must already be finite and clamped to the supported gain range. */
double BStreamDSPHeadroomDb(const double gainsDb[BSTREAM_DSP_BANDS]);

/* Allocate/release during setup/prepare, never in the realtime process callback.
 * Mutable state has one owner:
 * prepare/reset/set parameters/process/status all run on the audio thread.
 * A bridge must hand parameter snapshots to that thread, not mutate concurrently.
 */
BStreamDSP *BStreamDSPCreate(double sampleRate, uint32_t channels);
void BStreamDSPDestroy(BStreamDSP *dsp);
bool BStreamDSPSetEqualizer(BStreamDSP *dsp, bool enabled,
                          const double gainsDb[BSTREAM_DSP_BANDS],
                          uint64_t revision, bool immediate);
void BStreamDSPReset(BStreamDSP *dsp);
BStreamDSPStatus BStreamDSPGetStatus(const BStreamDSP *dsp);
bool BStreamDSPIsBypassed(const BStreamDSP *dsp);

/* In-place native-endian PCM, no allocations. For interleaved PCM pass one
 * buffer; for planar PCM pass one buffer per channel. Silence is measured
 * before equalization by the separate classifier below.
 */
void BStreamDSPProcessFloat32(BStreamDSP *dsp, void *const buffers[],
                             size_t frames, bool interleaved);
void BStreamDSPProcessFloat64(BStreamDSP *dsp, void *const buffers[],
                             size_t frames, bool interleaved);
void BStreamDSPProcessInt16(BStreamDSP *dsp, void *const buffers[],
                           size_t frames, bool interleaved);
void BStreamDSPProcessInt32(BStreamDSP *dsp, void *const buffers[],
                           size_t frames, bool interleaved);

typedef struct BStreamSilence BStreamSilence;
typedef struct {
    /* Absolute source-frame range to REMOVE, already retaining 150/250 ms.
     * Later events may extend a previously published range with the same start.
     */
    uint64_t startFrame;
    uint64_t endFrame;
} BStreamSilenceInterval;

/* The detector does not seek/drop audio. It exposes conservative intervals for
 * the native player's source-clock scheduler. Drain PopInterval after every
 * input chunk; repeated extensions are coalesced in a fixed queue (64 ranges).
 * No allocation occurs while analyzing a chunk. UINT64 frame positions remain
 * valid after Reset(startFrame, initialEdge=false), used for seek windows.
 */
BStreamSilence *BStreamSilenceCreate(double sampleRate, uint32_t channels,
                                    bool initialEdge);
void BStreamSilenceDestroy(BStreamSilence *silence);
void BStreamSilenceReset(BStreamSilence *silence, uint64_t startFrame,
                         bool initialEdge);
void BStreamSilenceProcessFloat32(BStreamSilence *silence,
                                 const void *const buffers[], size_t frames,
                                 bool interleaved);
void BStreamSilenceProcessFloat64(BStreamSilence *silence,
                                 const void *const buffers[], size_t frames,
                                 bool interleaved);
void BStreamSilenceProcessInt16(BStreamSilence *silence,
                               const void *const buffers[], size_t frames,
                               bool interleaved);
void BStreamSilenceProcessInt32(BStreamSilence *silence,
                               const void *const buffers[], size_t frames,
                               bool interleaved);
/* Call only at true source EOF, never merely at the end of a scan window. */
void BStreamSilenceFinish(BStreamSilence *silence);
bool BStreamSilencePopInterval(BStreamSilence *silence,
                              BStreamSilenceInterval *interval);
uint64_t BStreamSilenceAnalyzedFrames(const BStreamSilence *silence);
uint64_t BStreamSilenceDroppedIntervals(const BStreamSilence *silence);

#ifdef __cplusplus
}
#endif
#endif
