#import "./include/just_audio/BStreamAudioProcessingTap.h"
#import "./include/just_audio/BStreamAudioDSP.h"
#import <MediaToolbox/MediaToolbox.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    atomic_bool invalidated;
    atomic_bool supported;
    atomic_bool configured;
    atomic_bool statusChanged;
    atomic_uint_fast64_t sequence;
    atomic_bool enabled;
    atomic_int gains[BSTREAM_DSP_BANDS]; // milli-dB; atomic integers are lock-free on iOS.
    atomic_uint_fast64_t revision;
    atomic_uint_fast64_t resetEpoch;
    atomic_uint_fast64_t frames;
    atomic_int_fast64_t appliedRevision;
    atomic_int sampleRate;
    atomic_int channels;
    atomic_int encoding;
    atomic_int_fast64_t fadeOutUs;
    atomic_int_fast64_t fadeInUs;
    atomic_int outputGain; // -1: native owns volume; otherwise millionths.
    atomic_bool outputVolumeSupported;
    BStreamDSP *dsp; // Only the tap's prepare/process/unprepare thread owns DSP.
    AudioStreamBasicDescription format;
    uint64_t observedSequence;
    uint64_t observedReset;
    int observedGain;
    double currentGain;
    double gainStep;
    size_t gainFramesRemaining;
    bool interleaved;
    int sampleKind;
} BStreamTapState;

@interface BStreamAudioProcessingTap () {
@public
    BStreamTapState *_state;
@private
    __weak AVPlayerItem *_item;
    __weak AVAudioMix *_installedMix;
    BOOL _installing;
    BOOL _installed;
    BOOL _finishedInstalling;
    NSString *_error;
    double _watchPosition;
    uint64_t _watchFrames;
}
- (void)installIfPossible;
- (void)notifyStatus;
@end

static BStreamTapState *BSTapState(MTAudioProcessingTapRef tap) {
    return ((__bridge BStreamAudioProcessingTap *)MTAudioProcessingTapGetStorage(tap))->_state;
}

static void BSTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storage) {
    *storage = (void *)CFRetain(clientInfo);
}

static void BSTapFinalize(MTAudioProcessingTapRef tap) {
    CFRelease(MTAudioProcessingTapGetStorage(tap));
}

static void BSApplyParameters(BStreamTapState *state, bool immediate) {
    uint64_t before = atomic_load_explicit(&state->sequence, memory_order_acquire);
    if (before == state->observedSequence && !immediate) return;
    if (before & 1) return; // Never wait for the UI writer on the render thread.
    double gains[BSTREAM_DSP_BANDS];
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) gains[i] = atomic_load(&state->gains[i]) / 1000.0;
    bool enabled = atomic_load(&state->enabled);
    uint64_t revision = atomic_load(&state->revision);
    if (before != atomic_load_explicit(&state->sequence, memory_order_acquire)) return;
    BStreamDSPSetEqualizer(state->dsp, enabled, gains, revision, immediate);
    state->observedSequence = before;
}

static void BSTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                         const AudioStreamBasicDescription *format) {
    BStreamTapState *state = BSTapState(tap);
    BStreamDSPDestroy(state->dsp);
    state->dsp = NULL;
    state->format = *format;
    state->sampleKind = 0;
    state->interleaved = !(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    bool nativeEndian = !(format->mFormatFlags & kAudioFormatFlagIsBigEndian);
    if (format->mFormatID == kAudioFormatLinearPCM && nativeEndian) {
        if (format->mFormatFlags & kAudioFormatFlagIsFloat) {
            if (format->mBitsPerChannel == 32) state->sampleKind = 1;
            if (format->mBitsPerChannel == 64) state->sampleKind = 2;
        } else if (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
            if (format->mBitsPerChannel == 16) state->sampleKind = 3;
            if (format->mBitsPerChannel == 32) state->sampleKind = 4;
        }
    }
    size_t packedFrameBytes = (format->mBitsPerChannel / 8) * (state->interleaved ? format->mChannelsPerFrame : 1);
    if (format->mBytesPerFrame != packedFrameBytes || format->mFramesPerPacket != 1 ||
        !(format->mFormatFlags & kAudioFormatFlagIsPacked) || !isfinite(format->mSampleRate) ||
        format->mSampleRate <= 0 || format->mChannelsPerFrame == 0 ||
        format->mChannelsPerFrame > BSTREAM_DSP_MAX_CHANNELS) state->sampleKind = 0;
    if (state->sampleKind) state->dsp = BStreamDSPCreate(format->mSampleRate, format->mChannelsPerFrame);
    bool supported = state->dsp != NULL;
    // Keep this confirmation across unprepare; transient decoder rebuilds
    // must not transfer volume ownership back and forth.
    atomic_store(&state->outputVolumeSupported, state->sampleKind != 0);
    atomic_store(&state->supported, supported);
    atomic_store(&state->sampleRate, supported ? (int)format->mSampleRate : 0);
    atomic_store(&state->channels, supported ? (int)format->mChannelsPerFrame : 0);
    atomic_store(&state->encoding, supported ? (state->sampleKind <= 2 ? 4 : state->sampleKind == 3 ? 2 : 0x30000000) : 0);
    atomic_store(&state->appliedRevision, -1);
    atomic_store(&state->frames, 0);
    atomic_store(&state->configured, supported);
    atomic_store(&state->statusChanged, true);
    state->observedSequence = UINT64_MAX;
    state->observedReset = atomic_load(&state->resetEpoch);
    state->observedGain = atomic_load(&state->outputGain);
    state->currentGain = state->observedGain < 0 ? 1 : state->observedGain / 1000000.0;
    state->gainFramesRemaining = 0;
    if (supported) BSApplyParameters(state, true);
    // Prepare may allocate and report format changes. Process below never does.
    BStreamAudioProcessingTap *owner = (__bridge BStreamAudioProcessingTap *)MTAudioProcessingTapGetStorage(tap);
    __weak BStreamAudioProcessingTap *weakOwner = owner;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakOwner notifyStatus]; });
}

static void BSTapUnprepare(MTAudioProcessingTapRef tap) {
    BStreamTapState *state = BSTapState(tap);
    BStreamDSPDestroy(state->dsp);
    state->dsp = NULL;
    atomic_store(&state->configured, false);
    atomic_store(&state->appliedRevision, -1);
}

static void BSApplyFade(BStreamTapState *state, void *const buffers[], size_t frames,
                        double startSeconds, double secondsPerFrame, int64_t fadeOut, int64_t fadeIn) {
    int command = atomic_load(&state->outputGain);
    double targetGain = command < 0 ? 1 : command / 1000000.0;
    if ((command < 0) != (state->observedGain < 0)) {
        state->observedGain = command;
        state->currentGain = targetGain;
        state->gainFramesRemaining = 0;
    } else if (command != state->observedGain) {
        state->observedGain = command;
        state->gainFramesRemaining = (size_t)fmax(1, ceil(state->format.mSampleRate * 0.02));
        state->gainStep = (targetGain - state->currentGain) / state->gainFramesRemaining;
    }
    if (!isfinite(startSeconds)) fadeOut = fadeIn = -1;
    if (fadeOut < 0 && fadeIn < 0 && !state->gainFramesRemaining && state->currentGain == 1) return;
    size_t channels = state->format.mChannelsPerFrame;
    for (size_t frame = 0; frame < frames; frame++) {
        if (state->gainFramesRemaining) {
            state->currentGain += state->gainStep;
            if (--state->gainFramesRemaining == 0) state->currentGain = targetGain;
        }
        double timeUs = (startSeconds + frame * secondsPerFrame) * 1000000.0;
        double gain = state->currentGain;
        if (fadeOut >= 0 && timeUs >= fadeOut - 20000) gain *= fmax(0, fmin(1, (fadeOut - timeUs) / 20000));
        if (fadeIn >= 0 && timeUs >= fadeIn) gain *= fmax(0, fmin(1, (timeUs - fadeIn) / 20000));
        if (gain == 1) continue;
        for (size_t channel = 0; channel < channels; channel++) {
            size_t index = state->interleaved ? frame * channels + channel : frame;
            void *buffer = buffers[state->interleaved ? 0 : channel];
            switch (state->sampleKind) {
                case 1: ((float *)buffer)[index] *= (float)gain; break;
                case 2: ((double *)buffer)[index] *= gain; break;
                case 3: ((int16_t *)buffer)[index] = (int16_t)lrint(((int16_t *)buffer)[index] * gain); break;
                case 4: ((int32_t *)buffer)[index] = (int32_t)llrint(((int32_t *)buffer)[index] * gain); break;
            }
        }
    }
}

static void BSWithholdUnprocessedGain(BStreamTapState *state, AudioBufferList *buffers) {
    if (atomic_load(&state->outputGain) < 0) return;
    // The main-thread status callback restores native attenuation. Until that
    // acknowledgement, never pass a tap-owned muted/attenuated buffer at unity.
    size_t channelsPerBuffer = state->interleaved ? state->format.mChannelsPerFrame : 1;
    size_t sampleBytes = channelsPerBuffer ? state->format.mBytesPerFrame / channelsPerBuffer : 0;
    BOOL unsignedPCM = state->format.mFormatID == kAudioFormatLinearPCM &&
        !(state->format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger));
    size_t midpointBit = state->format.mFormatFlags & kAudioFormatFlagIsAlignedHigh
        ? sampleBytes * 8 - 1 : state->format.mBitsPerChannel - 1;
    for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
        AudioBuffer buffer = buffers->mBuffers[i];
        if (!buffer.mData) continue;
        memset(buffer.mData, 0, buffer.mDataByteSize);
        if (unsignedPCM && sampleBytes > 0 && sampleBytes <= 8 && midpointBit < sampleBytes * 8) {
            size_t byte = state->format.mFormatFlags & kAudioFormatFlagIsBigEndian
                ? sampleBytes - 1 - midpointBit / 8 : midpointBit / 8;
            for (size_t offset = 0; offset + sampleBytes <= buffer.mDataByteSize; offset += sampleBytes) {
                ((uint8_t *)buffer.mData)[offset + byte] = (uint8_t)(1u << (midpointBit % 8));
            }
        }
    }
}

static void BSTapProcess(MTAudioProcessingTapRef tap, CMItemCount requested,
                         MTAudioProcessingTapFlags flags, AudioBufferList *buffers,
                         CMItemCount *produced, MTAudioProcessingTapFlags *outputFlags) {
    CMTimeRange timeRange = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, outputFlags, &timeRange, produced);
    if (status != noErr) { *produced = 0; return; }
    BStreamTapState *state = BSTapState(tap);
    if (atomic_load(&state->invalidated) || *produced <= 0) return;
    if (!state->sampleKind) {
        BSWithholdUnprocessedGain(state, buffers);
        return;
    }
    size_t count = state->interleaved ? 1 : state->format.mChannelsPerFrame;
    if (count > BSTREAM_DSP_MAX_CHANNELS || buffers->mNumberBuffers < count) {
        atomic_store(&state->supported, false);
        atomic_store(&state->configured, false);
        atomic_store(&state->outputVolumeSupported, false);
        atomic_store(&state->statusChanged, true);
        BSWithholdUnprocessedGain(state, buffers);
        return;
    }
    void *data[BSTREAM_DSP_MAX_CHANNELS];
    size_t sampleSize = state->format.mBitsPerChannel / 8;
    for (size_t i = 0; i < count; i++) {
        data[i] = buffers->mBuffers[i].mData;
        size_t needed = (size_t)*produced * sampleSize * (state->interleaved ? state->format.mChannelsPerFrame : 1);
        if (!data[i] || buffers->mBuffers[i].mDataByteSize < needed) {
            atomic_store(&state->supported, false);
            atomic_store(&state->configured, false);
            atomic_store(&state->outputVolumeSupported, false);
            atomic_store(&state->statusChanged, true);
            BSWithholdUnprocessedGain(state, buffers);
            return;
        }
    }
    if (atomic_load(&state->supported) && state->dsp) {
        uint64_t reset = atomic_load(&state->resetEpoch);
        if (reset != state->observedReset || ((flags | *outputFlags) & kMTAudioProcessingTapFlag_StartOfStream)) {
            BStreamDSPReset(state->dsp);
            state->observedReset = reset;
            BSApplyParameters(state, true);
        } else {
            BSApplyParameters(state, false);
        }
        switch (state->sampleKind) {
            case 1: BStreamDSPProcessFloat32(state->dsp, data, (size_t)*produced, state->interleaved); break;
            case 2: BStreamDSPProcessFloat64(state->dsp, data, (size_t)*produced, state->interleaved); break;
            case 3: BStreamDSPProcessInt16(state->dsp, data, (size_t)*produced, state->interleaved); break;
            case 4: BStreamDSPProcessInt32(state->dsp, data, (size_t)*produced, state->interleaved); break;
        }
        BStreamDSPStatus result = BStreamDSPGetStatus(state->dsp);
        atomic_store(&state->appliedRevision, result.appliedRevision == UINT64_MAX ? -1 : (int64_t)result.appliedRevision);
    }
    atomic_fetch_add(&state->frames, (uint64_t)*produced);
    double start = CMTimeGetSeconds(timeRange.start);
    int_fast64_t fadeIn = atomic_load(&state->fadeInUs);
    if (isfinite(start) && fadeIn >= 0 && start * 1000000 >= fadeIn + 20000) {
        atomic_compare_exchange_strong(&state->fadeInUs, &fadeIn, -1);
        fadeIn = atomic_load(&state->fadeInUs);
    }
    double sourceDuration = CMTimeGetSeconds(timeRange.duration);
    double secondsPerFrame = isfinite(sourceDuration) && sourceDuration > 0
        ? sourceDuration / *produced : 1.0 / state->format.mSampleRate;
    BSApplyFade(state, data, (size_t)*produced, start, secondsPerFrame,
                atomic_load(&state->fadeOutUs), fadeIn);
    // AVPlayer owns the timeline: preserve every frame. Unity-gain EQ bypass
    // leaves data unchanged; silence removal uses separately scheduled seeks.
}

@implementation BStreamAudioProcessingTap

- (instancetype)initWithItem:(AVPlayerItem *)item {
    self = [super init];
    if (!self) return nil;
    _item = item;
    _watchPosition = NAN;
    _state = calloc(1, sizeof(BStreamTapState));
    if (!_state) return nil;
    atomic_init(&_state->invalidated, false);
    atomic_init(&_state->supported, true);
    atomic_init(&_state->configured, false);
    atomic_init(&_state->statusChanged, false);
    atomic_init(&_state->sequence, 0);
    atomic_init(&_state->enabled, false);
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) atomic_init(&_state->gains[i], 0);
    atomic_init(&_state->revision, 0);
    atomic_init(&_state->resetEpoch, 0);
    atomic_init(&_state->frames, 0);
    atomic_init(&_state->appliedRevision, -1);
    atomic_init(&_state->sampleRate, 0);
    atomic_init(&_state->channels, 0);
    atomic_init(&_state->encoding, 0);
    atomic_init(&_state->fadeOutUs, -1);
    atomic_init(&_state->fadeInUs, -1);
    atomic_init(&_state->outputGain, -1);
    atomic_init(&_state->outputVolumeSupported, false);
    [self installIfPossible];
    return self;
}

- (BOOL)supported { return atomic_load(&_state->supported) && !atomic_load(&_state->invalidated); }
- (BOOL)configured { return atomic_load(&_state->configured); }
- (BOOL)ready { return _finishedInstalling; }
- (BOOL)outputVolumeSupported { return atomic_load(&_state->outputVolumeSupported); }
- (BOOL)consumeStatusChange { return atomic_exchange(&_state->statusChanged, false); }
- (NSString *)error { return _error ?: (self.supported ? nil : @"Unsupported PCM processing route"); }

- (void)notifyStatus {
    if (atomic_load(&_state->invalidated)) return;
    if (atomic_load(&_state->supported)) _error = nil;
    if (!atomic_load(&_state->supported) && !_error) _error = @"Unsupported PCM processing format";
    if (self.onStatusChange) self.onStatusChange();
}

- (void)installIfPossible {
    if (_installed || _installing || !_item || atomic_load(&_state->invalidated)) return;
    _installing = YES;
    AVAsset *asset = _item.asset;
    __weak BStreamAudioProcessingTap *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BStreamAudioProcessingTap *owner = weakSelf;
        if (!owner || owner->_finishedInstalling || atomic_load(&owner->_state->invalidated)) return;
        owner->_finishedInstalling = YES;
        owner->_error = @"Audio processing initialization timed out";
        atomic_store(&owner->_state->supported, false);
        [owner notifyStatus];
    });
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"hasProtectedContent", @"readable"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            BStreamAudioProcessingTap *owner = weakSelf;
            if (!owner || owner->_finishedInstalling || atomic_load(&owner->_state->invalidated)) return;
            owner->_installing = NO;
            owner->_finishedInstalling = YES;
            AVPlayerItem *item = owner->_item;
            NSError *error = nil;
            if (!item || [asset statusOfValueForKey:@"tracks" error:&error] != AVKeyValueStatusLoaded ||
                [asset statusOfValueForKey:@"hasProtectedContent" error:&error] != AVKeyValueStatusLoaded ||
                [asset statusOfValueForKey:@"readable" error:&error] != AVKeyValueStatusLoaded ||
                asset.hasProtectedContent || !asset.readable) {
                owner->_error = error.localizedDescription ?: @"Audio processing is unavailable for this asset";
                atomic_store(&owner->_state->supported, false);
                [owner notifyStatus];
                return;
            }
            NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            if (tracks.count != 1 || item.audioMix) {
                // Do not replace another consumer's audio mix or claim to EQ
                // additional tracks while only processing one of them.
                owner->_error = @"Audio processing needs one unmixed audio track";
                atomic_store(&owner->_state->supported, false);
                [owner notifyStatus];
                return;
            }
            MTAudioProcessingTapCallbacks callbacks = { kMTAudioProcessingTapCallbacksVersion_0,
                (__bridge void *)owner, BSTapInit, BSTapFinalize, BSTapPrepare, BSTapUnprepare, BSTapProcess };
            MTAudioProcessingTapRef tap = NULL;
            OSStatus result = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
            if (result != noErr || !tap) {
                if (tap) CFRelease(tap);
                owner->_error = @"Could not create the PCM processing tap";
                atomic_store(&owner->_state->supported, false);
                [owner notifyStatus];
                return;
            }
            AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
            parameters.audioTapProcessor = tap;
            AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
            mix.inputParameters = @[parameters];
            item.audioMix = mix;
            owner->_installedMix = item.audioMix;
            CFRelease(tap);
            owner->_installed = YES;
            [owner notifyStatus];
        });
    }];
}

- (void)configureEnabled:(BOOL)enabled gains:(NSArray<NSNumber *> *)gains revision:(uint64_t)revision {
    if (atomic_load(&_state->revision) == revision && atomic_load(&_state->enabled) == enabled) {
        BOOL same = YES;
        for (int i = 0; i < BSTREAM_DSP_BANDS; i++) same &= atomic_load(&_state->gains[i]) == (int)llround(gains[i].doubleValue * 1000);
        if (same) return;
    }
    atomic_fetch_add_explicit(&_state->sequence, 1, memory_order_acq_rel);
    atomic_store(&_state->enabled, enabled);
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) atomic_store(&_state->gains[i], (int)llround(gains[i].doubleValue * 1000));
    atomic_store(&_state->revision, revision);
    atomic_fetch_add_explicit(&_state->sequence, 1, memory_order_release);
}

- (void)configureOutputVolume:(float)volume enabled:(BOOL)enabled {
    int gain = enabled && isfinite(volume) ? (int)llround(fmax(0, fmin(1, volume)) * 1000000) : -1;
    atomic_store(&_state->outputGain, gain);
}

- (NSDictionary *)diagnostics {
    return @{ @"supported": @(self.supported), @"configured": @(self.configured),
              @"processedFrames": @(atomic_load(&_state->frames)),
              @"sampleRate": @(atomic_load(&_state->sampleRate)),
              @"channelCount": @(atomic_load(&_state->channels)),
              @"pcmEncoding": @(atomic_load(&_state->encoding)),
              @"appliedRevision": @(atomic_load(&_state->appliedRevision)),
              @"error": self.error ?: (id)[NSNull null] };
}

- (void)validatePlaybackAtTime:(CMTime)time {
    if (!self.ready || !self.supported) return;
    double position = CMTimeGetSeconds(time);
    uint64_t frames = atomic_load(&_state->frames);
    if (!isfinite(position)) return;
    if (frames > 0) {
        _watchPosition = NAN;
        return;
    }
    if (!isfinite(_watchPosition) || position < _watchPosition || frames != _watchFrames) {
        _watchPosition = position;
        _watchFrames = frames;
    } else if (position - _watchPosition > 1.5) {
        // Some AVPlayer routes ignore legacy audio mixes. Never present an
        // enabled EQ if the media clock advances without delivering any PCM.
        _error = @"This playback route does not expose PCM processing";
        atomic_store(&_state->supported, false);
        atomic_store(&_state->configured, false);
        [self notifyStatus];
    }
}

- (void)fadeOutAtTime:(CMTime)time {
    double seconds = CMTimeGetSeconds(time);
    atomic_store(&_state->fadeInUs, -1);
    atomic_store(&_state->fadeOutUs, isfinite(seconds) ? (int64_t)llround(seconds * 1000000) : -1);
}

- (void)resetAfterSeekToTime:(CMTime)time fadeIn:(BOOL)fadeIn {
    _watchPosition = NAN;
    double seconds = CMTimeGetSeconds(time);
    atomic_store(&_state->fadeOutUs, -1);
    atomic_store(&_state->fadeInUs, fadeIn && isfinite(seconds) ? (int64_t)llround(seconds * 1000000) : -1);
    atomic_fetch_add(&_state->resetEpoch, 1);
}

- (void)cancelFade {
    atomic_store(&_state->fadeOutUs, -1);
    atomic_store(&_state->fadeInUs, -1);
}

- (void)invalidate {
    atomic_store(&_state->invalidated, true);
    self.onStatusChange = nil;
    [self cancelFade];
    AVPlayerItem *item = _item;
    if (_installedMix && item.audioMix == _installedMix) item.audioMix = nil;
    _installedMix = nil;
}

- (void)dealloc {
    if (_state) {
        BStreamDSPDestroy(_state->dsp);
        free(_state);
    }
}
@end
