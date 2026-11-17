#import "./include/just_audio/BStreamSilenceAnalyzer.h"
#import "./include/just_audio/BStreamAudioDSP.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>

static const double BStreamSilenceLookaheadSeconds = 12.0;
static const NSUInteger BStreamSilenceMaximumRanges = 1024;

static double BStreamSeconds(CMTime time) {
    return CMTIME_IS_NUMERIC(time) ? CMTimeGetSeconds(time) : NAN;
}

static CMTime BStreamTime(double seconds) {
    return CMTimeMakeWithSeconds(seconds, 1000000);
}

static BOOL BStreamPermanentReaderFailure(NSError *error) {
    if (![error.domain isEqualToString:AVFoundationErrorDomain]) return NO;
    return error.code == AVErrorOperationNotSupportedForAsset ||
        error.code == AVErrorDecoderNotFound ||
        error.code == AVErrorFileFormatNotRecognized ||
        error.code == AVErrorContentIsProtected;
}

static NSCache<NSString *, id> *BStreamSilenceCache(void) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 32;
        cache.name = @"BStream bounded silence analysis";
    });
    return cache;
}

@class BStreamSilenceAnalysisEntry;
@interface BStreamSilenceAnalyzer ()
- (void)entryDidChange:(BStreamSilenceAnalysisEntry *)entry;
@end

/// One serial reader/classifier per cache entry. Its short synchronized sections
/// protect metadata only; no lock is held while AVAssetReader performs I/O.
@interface BStreamSilenceAnalysisEntry : NSObject {
    AVAsset *_asset;
    AVAssetTrack *_track;
    BOOL _local;
    dispatch_queue_t _queue;
    NSHashTable<BStreamSilenceAnalyzer *> *_observers;
    __weak BStreamSilenceAnalyzer *_pendingOwner;
    __weak BStreamSilenceAnalyzer *_activeOwner;
    NSMutableArray<NSValue *> *_gaps;
    NSMutableArray<NSValue *> *_coverage;
    AVAssetReader *_reader;
    BStreamSilence *_detector;
    double _sampleRate;
    uint32_t _channels;
    double _duration;
    double _cursor;
    double _segmentStart;
    double _pendingPosition;
    double _pendingEnd;
    double _activeStart;
    double _activeEnd;
    double _retryAfter;
    uint64_t _generation;
    uint64_t _decodedFrames;
    NSUInteger _readersCreated;
    NSUInteger _publicationRevision;
    NSUInteger _notifiedRevision;
    BOOL _supported;
    BOOL _ready;
    BOOL _inspected;
    BOOL _inspectionLoading;
    BOOL _scanScheduled;
    BOOL _pending;
    BOOL _needsReset;
    BOOL _notificationScheduled;
    NSString *_errorText;
    NSNumber *_errorCode;
    NSString *_errorDomain;
    NSNumber *_assetReadable;
    double _lastRequestedPosition;
    double _lastBufferedUntil;
    double _lastRequestedLimit;
}
- (instancetype)initWithAsset:(AVAsset *)asset;
- (void)addObserver:(BStreamSilenceAnalyzer *)observer;
- (void)removeObserver:(BStreamSilenceAnalyzer *)observer;
- (void)requestAt:(double)position bufferedUntil:(double)end observer:(BStreamSilenceAnalyzer *)observer;
- (nullable NSValue *)nextGapAt:(double)position;
- (NSDictionary<NSString *, id> *)snapshot;
- (BOOL)isSupported;
- (BOOL)isReady;
- (nullable NSString *)errorText;
- (void)notifyObservers;
- (void)inspectIfNeeded;
- (void)schedulePendingScan;
- (double)coverageEndForPosition:(double)position;
- (void)mergeRange:(CMTimeRange)range into:(NSMutableArray<NSValue *> *)ranges;
- (BOOL)isCurrentGeneration:(uint64_t)generation;
- (void)drainDetectorIntervals;
- (void)runPendingScan;
- (void)finishScan:(nullable AVAssetReader *)reader generation:(uint64_t)generation;
@end

@implementation BStreamSilenceAnalysisEntry

- (instancetype)initWithAsset:(AVAsset *)asset {
    self = [super init];
    if (!self) return nil;
    _asset = asset;
    _local = [asset isKindOfClass:[AVURLAsset class]] && ((AVURLAsset *)asset).URL.isFileURL;
    _queue = dispatch_queue_create("com.bstream.silence.analysis", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    _observers = [NSHashTable weakObjectsHashTable];
    _gaps = [NSMutableArray array];
    _coverage = [NSMutableArray array];
    _duration = _cursor = _segmentStart = _activeStart = _activeEnd = NAN;
    _lastRequestedPosition = _lastBufferedUntil = _lastRequestedLimit = NAN;
    _supported = YES;
    _needsReset = YES;
    return self;
}

- (void)dealloc {
    [_reader cancelReading];
    BStreamSilenceDestroy(_detector);
}

- (void)addObserver:(BStreamSilenceAnalyzer *)observer {
    @synchronized (self) { [_observers addObject:observer]; }
}

- (void)removeObserver:(BStreamSilenceAnalyzer *)observer {
    AVAssetReader *cancel = nil;
    @synchronized (self) {
        [_observers removeObject:observer];
        if (_pendingOwner == observer) {
            _pending = NO;
            _pendingOwner = nil;
        }
        if (_observers.count == 0 || _activeOwner == observer) {
            ++_generation;
            if (_observers.count == 0) _pending = NO;
            _needsReset = YES;
            cancel = _reader;
        }
    }
    // Do not cancel AVAsset loading: that asset also belongs to AVQueuePlayer.
    // A reader is independent and may safely be cancelled when the last user
    // disables the feature or removes its item.
    [cancel cancelReading];
}

- (void)notifyObservers {
    @synchronized (self) {
        if (_notificationScheduled || _publicationRevision == _notifiedRevision) return;
        _notificationScheduled = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<BStreamSilenceAnalyzer *> *observers;
        @synchronized (self) {
            self->_notificationScheduled = NO;
            self->_notifiedRevision = self->_publicationRevision;
            observers = self->_observers.allObjects;
        }
        for (BStreamSilenceAnalyzer *observer in observers) [observer entryDidChange:self];
    });
}

- (void)rejectSource:(NSString *)message code:(nullable NSNumber *)code domain:(nullable NSString *)domain {
    @synchronized (self) {
        _supported = NO;
        _errorText = message;
        _errorCode = code;
        _errorDomain = domain;
        _pending = NO;
        ++_publicationRevision;
    }
    [self notifyObservers];
}

- (void)inspectIfNeeded {
    @synchronized (self) {
        if (_inspected || _inspectionLoading || !_supported || _observers.count == 0) return;
        _inspectionLoading = YES;
    }
    if ([_asset isKindOfClass:[AVURLAsset class]]) {
        NSString *extension = ((AVURLAsset *)_asset).URL.pathExtension.lowercaseString;
        if ([extension isEqualToString:@"m3u8"] || [extension isEqualToString:@"m3u"]) {
            [self rejectSource:@"Live or HLS media cannot be read for silence analysis." code:nil domain:nil];
            return;
        }
    }
    NSArray<NSString *> *keys = @[@"tracks", @"duration", @"readable", @"hasProtectedContent"];
    [_asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        dispatch_async(self->_queue, ^{
            for (NSString *key in keys) {
                NSError *error = nil;
                if ([self->_asset statusOfValueForKey:key error:&error] != AVKeyValueStatusLoaded) {
                    [self rejectSource:@"The source could not be inspected for silence analysis."
                                   code:error ? @(error.code) : nil domain:error.domain];
                    return;
                }
            }
            BOOL readable = self->_asset.readable;
            @synchronized (self) { self->_assetReadable = @(readable); }
            if (self->_asset.hasProtectedContent || !readable) {
                [self rejectSource:@"Protected or unreadable media does not support silence analysis." code:nil domain:nil];
                return;
            }
            double duration = BStreamSeconds(self->_asset.duration);
            if (!isfinite(duration) || duration <= 0) {
                [self rejectSource:@"A finite source duration is required for silence analysis." code:nil domain:nil];
                return;
            }
            NSArray<AVAssetTrack *> *tracks = [self->_asset tracksWithMediaType:AVMediaTypeAudio];
            AVAssetTrack *track = nil;
            if (tracks.count == 1) {
                track = tracks.firstObject;
            }
            if (!track) {
                [self rejectSource:@"A single selected audio track is required for silence analysis." code:nil domain:nil];
                return;
            }
            @synchronized (self) {
                self->_duration = duration;
                self->_track = track;
                self->_inspected = YES;
                self->_inspectionLoading = NO;
            }
            [self schedulePendingScan];
        });
    }];
}

- (void)requestAt:(double)position bufferedUntil:(double)end observer:(BStreamSilenceAnalyzer *)observer {
    if (!isfinite(position) || position < 0) return;
    AVAssetReader *cancel = nil;
    @synchronized (self) {
        _lastRequestedPosition = position;
        _lastBufferedUntil = end;
        _lastRequestedLimit = NAN;
        if (!_supported || _observers.count == 0) return;
        double limit = position + BStreamSilenceLookaheadSeconds;
        if (!_local) {
            // Never deliberately read beyond the range already available to
            // playback. A remote AVAssetReader can still need its own decoder
            // and compressed-data reads; it runs only while skip is enabled.
            if (!isfinite(end) || end <= position) return;
            limit = MIN(limit, end);
        }
        if (isfinite(_duration)) limit = MIN(limit, _duration);
        _lastRequestedLimit = limit;
        if (limit <= position + 0.005) return;
        if ([self coverageEndForPosition:position] >= limit - 0.005) return;
        // One deck must not continually cancel another deck's reader when a
        // repeat/crossfade uses the same file at a different source position.
        BOOL outsideActive = _scanScheduled && _activeOwner == observer && isfinite(_activeStart) &&
            (position < _activeStart - 0.05 || position > _activeEnd + 0.05);
        if (outsideActive) {
            ++_generation;
            _needsReset = YES;
            cancel = _reader;
        }
        // Coalescing keeps only the latest bounded window, including after a
        // backward seek or a shrinking buffered range. Never accumulate a
        // horizon beyond twelve seconds from the latest playback position.
        _pendingEnd = limit;
        _pendingPosition = position;
        _pending = YES;
        _pendingOwner = observer;
    }
    [cancel cancelReading];
    [self inspectIfNeeded];
    [self schedulePendingScan];
}

- (void)schedulePendingScan {
    @synchronized (self) {
        if (!_inspected || !_supported || !_pending || _scanScheduled ||
                _observers.count == 0 || NSProcessInfo.processInfo.systemUptime < _retryAfter) return;
        _scanScheduled = YES;
    }
    dispatch_async(_queue, ^{ [self runPendingScan]; });
}

- (double)coverageEndForPosition:(double)position {
    for (NSValue *value in _coverage) {
        CMTimeRange range = value.CMTimeRangeValue;
        double start = BStreamSeconds(range.start);
        double end = BStreamSeconds(CMTimeRangeGetEnd(range));
        if (position >= start - 0.00001 && position <= end + 0.00001) return end;
    }
    return position;
}

- (void)mergeRange:(CMTimeRange)range into:(NSMutableArray<NSValue *> *)ranges {
    if (!CMTIMERANGE_IS_VALID(range) || CMTimeCompare(range.duration, kCMTimeZero) <= 0) return;
    [ranges addObject:[NSValue valueWithCMTimeRange:range]];
    [ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        int comparison = CMTimeCompare(a.CMTimeRangeValue.start, b.CMTimeRangeValue.start);
        return comparison < 0 ? NSOrderedAscending : comparison > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSUInteger i = 1; i < ranges.count;) {
        CMTimeRange previous = ranges[i - 1].CMTimeRangeValue;
        CMTimeRange current = ranges[i].CMTimeRangeValue;
        if (CMTimeCompare(current.start, CMTimeRangeGetEnd(previous)) <= 0) {
            CMTime end = CMTimeMaximum(CMTimeRangeGetEnd(previous), CMTimeRangeGetEnd(current));
            ranges[i - 1] = [NSValue valueWithCMTimeRange:CMTimeRangeFromTimeToTime(previous.start, end)];
            [ranges removeObjectAtIndex:i];
        } else {
            ++i;
        }
    }
    if (ranges.count > BStreamSilenceMaximumRanges) {
        [ranges removeObjectsInRange:NSMakeRange(0, ranges.count - BStreamSilenceMaximumRanges)];
        // Forget coverage as well when old interval metadata is evicted. A
        // backward seek may then re-analyze that region instead of falsely
        // treating missing cached intervals as a completed no-silence scan.
        double retainedStart = BStreamSeconds(ranges.firstObject.CMTimeRangeValue.start);
        if (ranges != _coverage) [_coverage removeAllObjects];
        _segmentStart = isfinite(_segmentStart) ? MAX(_segmentStart, retainedStart) : retainedStart;
    }
}

- (BOOL)isCurrentGeneration:(uint64_t)generation {
    @synchronized (self) { return generation == _generation && _observers.count > 0; }
}

- (void)drainDetectorIntervals {
    BStreamSilenceInterval interval;
    @synchronized (self) {
        while (BStreamSilencePopInterval(_detector, &interval)) {
            CMTime start = BStreamTime((double)interval.startFrame / _sampleRate);
            CMTime end = BStreamTime((double)interval.endFrame / _sampleRate);
            BOOL covered = NO;
            for (NSValue *value in _gaps) {
                CMTimeRange previous = value.CMTimeRangeValue;
                if (CMTimeCompare(start, previous.start) >= 0 &&
                        CMTimeCompare(end, CMTimeRangeGetEnd(previous)) <= 0) {
                    covered = YES;
                    break;
                }
            }
            if (covered) continue;
            [self mergeRange:CMTimeRangeFromTimeToTime(start, end) into:_gaps];
            ++_publicationRevision;
        }
    }
}

- (void)runPendingScan {
    double position, end, start;
    BOOL reset;
    uint64_t generation;
    @synchronized (self) {
        if (!_pending || !_supported || _observers.count == 0) {
            _scanScheduled = NO;
            _activeOwner = nil;
            return;
        }
        position = _pendingPosition;
        end = MIN(_pendingEnd, _duration);
        _pending = NO;
        _activeOwner = _pendingOwner;
        _pendingOwner = nil;
        generation = _generation;
        double coveredUntil = [self coverageEndForPosition:position];
        BOOL canContinue = !_needsReset && isfinite(_cursor) &&
            position >= _segmentStart - 0.00001 && position <= _cursor + 0.00001;
        start = canContinue ? _cursor : MAX(position, coveredUntil);
        reset = !canContinue;
        if (end <= start + 0.005) {
            _scanScheduled = NO;
            _activeOwner = nil;
            return;
        }
        BOOL atSourceEnd = end >= _duration - 0.00001;
        double extension = end - start;
        double analyzedAhead = start - position;
        if (!reset && !atSourceEnd &&
                ((analyzedAhead >= 4.5 && extension < 4.0) || extension < 0.5)) {
            // AVAssetReader's timeRange is immutable after startReading. Batch
            // extensions instead of recreating a decoder on every 200 ms
            // playback tick. With ample buffering this opens one reader for
            // several seconds; a smaller buffer permits half-second refills.
            _scanScheduled = NO;
            _activeOwner = nil;
            return;
        }
        _activeStart = position;
        _activeEnd = end;
    }

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:_asset error:&readerError];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsBigEndianKey: @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:_track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    BOOL outputSupported = reader && [reader canAddOutput:output];
    BOOL began = outputSupported;
    if (began) {
        [reader addOutput:output];
        reader.timeRange = CMTimeRangeFromTimeToTime(BStreamTime(start), BStreamTime(end));
        @synchronized (self) {
            if (generation == _generation && _observers.count > 0) {
                ++_readersCreated;
            } else {
                began = NO;
            }
        }
        if (began) began = [reader startReading];
        @synchronized (self) {
            if (began && generation == _generation && _observers.count > 0) {
                // Cancellation must not tear down AVFoundation's mixdown
                // channel while startReading is still constructing it.
                _reader = reader;
            } else if (generation != _generation || _observers.count == 0) {
                began = NO;
            }
        }
    }
    if (!began) {
        if ([self isCurrentGeneration:generation]) {
            NSError *error = reader.error ?: readerError;
            if ((reader && !outputSupported) || BStreamPermanentReaderFailure(error)) {
                [self rejectSource:@"This source cannot be decoded for silence analysis."
                               code:error ? @(error.code) : nil domain:error.domain];
            } else {
                @synchronized (self) {
                    NSString *message = @"The source could not be decoded for silence analysis.";
                    NSNumber *code = error ? @(error.code) : nil;
                    if (![_errorText isEqualToString:message] ||
                            !(_errorCode == code || [_errorCode isEqual:code])) ++_publicationRevision;
                    _errorText = message;
                    _errorCode = code;
                    _errorDomain = error.domain;
                    _retryAfter = NSProcessInfo.processInfo.systemUptime + 1;
                    _needsReset = YES;
                }
            }
        }
        [self finishScan:reader generation:generation];
        return;
    }

    BOOL validPCM = YES;
    double scannedStart = start;
    double scannedUntil = start;
    while ([self isCurrentGeneration:generation]) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (!sample) break;
            if (![self isCurrentGeneration:generation]) {
                CFRelease(sample);
                break;
            }
            CMItemCount sampleCount = CMSampleBufferGetNumSamples(sample);
            if (sampleCount <= 0) {
                // Marker buffers do not contain PCM and cannot prove silence.
                if (_detector) BStreamSilenceReset(_detector,
                    BStreamSilenceAnalyzedFrames(_detector), false);
                CFRelease(sample);
                continue;
            }
            CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
            // A sample buffer may have no format description. Validate it
            // before calling the audio-specific CoreMedia accessor.
            const AudioStreamBasicDescription *format = description &&
                CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio
                ? CMAudioFormatDescriptionGetStreamBasicDescription(description) : NULL;
            double sampleTime = BStreamSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            BOOL acceptable = format && format->mFormatID == kAudioFormatLinearPCM &&
                (format->mFormatFlags & kAudioFormatFlagIsFloat) &&
                !(format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) &&
                !(format->mFormatFlags & kAudioFormatFlagIsBigEndian) &&
                format->mBitsPerChannel == 32 && format->mChannelsPerFrame > 0 &&
                format->mChannelsPerFrame <= BSTREAM_DSP_MAX_CHANNELS &&
                format->mBytesPerFrame == format->mChannelsPerFrame * sizeof(float) &&
                isfinite(format->mSampleRate) && format->mSampleRate > 0 && isfinite(sampleTime);
            if (!acceptable) {
                CFRelease(sample);
                validPCM = NO;
                break;
            }
            if (!_detector || _sampleRate != format->mSampleRate || _channels != format->mChannelsPerFrame) {
                BStreamSilenceDestroy(_detector);
                _sampleRate = format->mSampleRate;
                _channels = format->mChannelsPerFrame;
                _detector = BStreamSilenceCreate(_sampleRate, _channels, start <= 0.00001);
                reset = YES;
            }
            if (!_detector) {
                CFRelease(sample);
                validPCM = NO;
                break;
            }
            if (reset) {
                uint64_t firstFrame = (uint64_t)llround(MAX(start, sampleTime) * _sampleRate);
                // A genuine initial read may start at a positive track PTS
                // because of an edit/encoder offset. A later seek is never an
                // initial edge, even if the decoder supplies some preroll.
                BStreamSilenceReset(_detector, firstFrame, start <= 0.00001);
                @synchronized (self) {
                    _segmentStart = (double)firstFrame / _sampleRate;
                    _cursor = _segmentStart;
                    _needsReset = NO;
                }
                scannedStart = _segmentStart;
                reset = NO;
            }
            int64_t sourceFrame = (int64_t)llround(sampleTime * _sampleRate);
            uint64_t nextFrame = BStreamSilenceAnalyzedFrames(_detector);
            if (sourceFrame > 0 && (uint64_t)sourceFrame > nextFrame + 2) {
                // A decoder timestamp discontinuity is not evidence of silence.
                @synchronized (self) {
                    double previousEnd = (double)nextFrame / _sampleRate;
                    if (previousEnd > scannedStart) {
                        [self mergeRange:CMTimeRangeFromTimeToTime(BStreamTime(scannedStart), BStreamTime(previousEnd)) into:_coverage];
                    }
                    scannedStart = (double)sourceFrame / _sampleRate;
                    _segmentStart = scannedStart;
                }
                BStreamSilenceReset(_detector, (uint64_t)sourceFrame, false);
                nextFrame = (uint64_t)sourceFrame;
            }
            size_t sampleFrames = (size_t)sampleCount;
            // Decoders may expose negative encoder-preroll timestamps. Trim
            // those samples instead of shifting the analyzed source timeline.
            int64_t skipped = (int64_t)nextFrame - sourceFrame;
            size_t trim = skipped > 0 ? (size_t)MIN((uint64_t)skipped, sampleFrames) : 0;
            uint64_t limitFrame = (uint64_t)llround(end * _sampleRate);
            int64_t signedFirstFrame = sourceFrame + (int64_t)trim;
            uint64_t firstFrame = signedFirstFrame >= 0 ? (uint64_t)signedFirstFrame : UINT64_MAX;
            size_t frames = firstFrame < limitFrame
                ? (size_t)MIN((uint64_t)(sampleFrames - trim), limitFrame - firstFrame) : 0;
            AudioBufferList buffers;
            CMBlockBufferRef retainedBuffer = NULL;
            OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, NULL, &buffers, sizeof(buffers), kCFAllocatorDefault, kCFAllocatorDefault,
                kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retainedBuffer);
            if (status != noErr || buffers.mNumberBuffers != 1 || !buffers.mBuffers[0].mData ||
                    buffers.mBuffers[0].mDataByteSize < (trim + frames) * _channels * sizeof(float)) {
                if (retainedBuffer) CFRelease(retainedBuffer);
                CFRelease(sample);
                validPCM = NO;
                break;
            }
            if (frames > 0) {
                const void *input[] = {(const float *)buffers.mBuffers[0].mData + trim * _channels};
                BStreamSilenceProcessFloat32(_detector, input, frames, true);
                scannedUntil = (double)BStreamSilenceAnalyzedFrames(_detector) / _sampleRate;
                @synchronized (self) {
                    _cursor = scannedUntil;
                    _decodedFrames += frames;
                }
                [self drainDetectorIntervals];
            }
            if (retainedBuffer) CFRelease(retainedBuffer);
            CFRelease(sample);
            if (scannedUntil >= end - 1.0 / _sampleRate && end < _duration - 0.00001) break;
        }
    }
    if ([self isCurrentGeneration:generation]) {
        if (!validPCM) {
            [self rejectSource:@"The decoded PCM format is unavailable for silence analysis." code:nil domain:nil];
        } else {
            // Reader completion at a bounded window is not source EOF. Only
            // finish the classifier at the actual asset end, never at a seek
            // or the caller's buffered horizon.
            if (end >= _duration - 0.00001 && scannedUntil >= _duration - 0.02 &&
                    reader.status == AVAssetReaderStatusCompleted) {
                BStreamSilenceFinish(_detector);
                [self drainDetectorIntervals];
            }
            @synchronized (self) {
                if (scannedUntil > scannedStart) {
                    [self mergeRange:CMTimeRangeFromTimeToTime(BStreamTime(scannedStart), BStreamTime(scannedUntil)) into:_coverage];
                    if (!_ready) ++_publicationRevision;
                    _ready = YES;
                }
                if (reader.status == AVAssetReaderStatusCompleted && scannedUntil <= scannedStart + 0.00001) {
                    // A sparse/muxed track may end before AVAsset.duration, or
                    // a truncated source may expose no PCM for this range.
                    // Do not call Finish (the asset did not reach EOF), mark
                    // unknown time as silence, or reopen an empty decoder on
                    // every playback tick.
                    NSString *message = @"No decoded audio was available for the requested analysis window.";
                    if (![_errorText isEqualToString:message] || _errorCode) ++_publicationRevision;
                    _errorText = message;
                    _errorCode = nil;
                    _errorDomain = nil;
                    _retryAfter = NSProcessInfo.processInfo.systemUptime + 4;
                    _needsReset = YES;
                } else if (reader.status == AVAssetReaderStatusFailed && !BStreamPermanentReaderFailure(reader.error)) {
                    _errorText = @"The source decoder could not complete the requested analysis window.";
                    _errorCode = reader.error ? @(reader.error.code) : nil;
                    _errorDomain = reader.error.domain;
                    ++_publicationRevision;
                    _retryAfter = NSProcessInfo.processInfo.systemUptime + 1;
                    _needsReset = YES;
                } else {
                    if (_errorText) ++_publicationRevision;
                    _errorText = nil;
                    _errorCode = nil;
                    _errorDomain = nil;
                }
            }
            if (reader.status == AVAssetReaderStatusFailed && BStreamPermanentReaderFailure(reader.error)) {
                [self rejectSource:@"This source cannot be decoded for silence analysis." code:@(reader.error.code) domain:reader.error.domain];
            }
        }
    }
    [self finishScan:reader generation:generation];
}

- (void)finishScan:(nullable AVAssetReader *)reader generation:(uint64_t)generation {
    [reader cancelReading];
    @synchronized (self) {
        if (_reader == reader) _reader = nil;
        _scanScheduled = NO;
        _activeStart = _activeEnd = NAN;
        _activeOwner = nil;
        if (generation != _generation) _needsReset = YES;
    }
    [self notifyObservers];
    [self schedulePendingScan];
}

- (nullable NSValue *)nextGapAt:(double)position {
    if (!isfinite(position)) return nil;
    @synchronized (self) {
        if (!_supported) return nil;
        for (NSValue *value in _gaps) {
            if (BStreamSeconds(CMTimeRangeGetEnd(value.CMTimeRangeValue)) > position + 0.00001) return value;
        }
    }
    return nil;
}

- (NSDictionary<NSString *, id> *)snapshot {
    @synchronized (self) {
        NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:_gaps.count];
        for (NSValue *value in _gaps) {
            CMTimeRange range = value.CMTimeRangeValue;
            [ranges addObject:@{
                @"startMs": @(llround(BStreamSeconds(range.start) * 1000)),
                @"endMs": @(llround(BStreamSeconds(CMTimeRangeGetEnd(range)) * 1000)),
            }];
        }
        return @{
            @"supported": @(_supported), @"ready": @(_ready),
            @"engine": @"bstream-ios-silence", @"source": _local ? @"local" : @"progressive",
            @"error": _errorText ?: (id)[NSNull null], @"errorCode": _errorCode ?: (id)[NSNull null],
            @"errorDomain": _errorDomain ?: (id)[NSNull null],
            @"assetReadable": _assetReadable ?: (id)[NSNull null],
            @"lastPositionSeconds": isfinite(_lastRequestedPosition) ? @(_lastRequestedPosition) : (id)[NSNull null],
            @"lastBufferedUntilSeconds": isfinite(_lastBufferedUntil) ? @(_lastBufferedUntil) : (id)[NSNull null],
            @"lastLimitSeconds": isfinite(_lastRequestedLimit) ? @(_lastRequestedLimit) : (id)[NSNull null],
            @"analyzedUntilMs": @(isfinite(_cursor) ? llround(_cursor * 1000) : 0),
            @"decodedFrames": @(_decodedFrames), @"readersCreated": @(_readersCreated),
            @"sharedUsers": @(_observers.count), @"ranges": ranges,
            @"analyzing": @(_scanScheduled),
            @"lookaheadSeconds": @(BStreamSilenceLookaheadSeconds),
        };
    }
}

- (BOOL)isSupported { @synchronized (self) { return _supported; } }
- (BOOL)isReady { @synchronized (self) { return _ready; } }
- (nullable NSString *)errorText { @synchronized (self) { return _errorText; } }

@end

@implementation BStreamSilenceAnalyzer {
    BStreamSilenceAnalysisEntry *_entry;
    BOOL _invalidated;
    BOOL _publishedInitialState;
    __weak AVPlayerItem *_item;
    NSTimeInterval _originalForwardBufferDuration;
    NSTimeInterval _assignedForwardBufferDuration;
    BOOL _changedForwardBufferDuration;
}

- (instancetype)initWithItem:(AVPlayerItem *)item {
    return [self initWithItem:item cacheIdentifier:nil];
}

- (instancetype)initWithItem:(AVPlayerItem *)item cacheIdentifier:(nullable NSString *)cacheIdentifier {
    self = [super init];
    if (!self) return nil;
    AVAsset *asset = item.asset;
    _item = item;
    _originalForwardBufferDuration = item.preferredForwardBufferDuration;
    if (_originalForwardBufferDuration < BStreamSilenceLookaheadSeconds) {
        _assignedForwardBufferDuration = BStreamSilenceLookaheadSeconds;
        item.preferredForwardBufferDuration = _assignedForwardBufferDuration;
        _changedForwardBufferDuration = YES;
    }
    NSString *key;
    if (cacheIdentifier.length > 0) {
        key = [@"provided:" stringByAppendingString:cacheIdentifier];
    } else if ([asset isKindOfClass:[AVURLAsset class]] && ((AVURLAsset *)asset).URL.isFileURL) {
        NSURL *url = ((AVURLAsset *)asset).URL.URLByStandardizingPath;
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL];
        NSDate *modified = attributes[NSFileModificationDate];
        key = [NSString stringWithFormat:@"local:%@:%@:%@:%0.17g", url.absoluteString,
               attributes[NSFileSize] ?: @0, attributes[NSFileSystemFileNumber] ?: @0,
               modified ? modified.timeIntervalSince1970 : 0.0];
    } else {
        // AVURLAsset does not expose its original request headers. Pointer
        // identity safely shares the same asset without mixing credentials.
        key = [NSString stringWithFormat:@"asset:%p", asset];
    }
    NSCache *cache = BStreamSilenceCache();
    @synchronized (cache) {
        _entry = [cache objectForKey:key];
        if (!_entry) {
            _entry = [[BStreamSilenceAnalysisEntry alloc] initWithAsset:asset];
            [cache setObject:_entry forKey:key];
        }
    }
    [_entry addObserver:self];
    return self;
}

- (void)dealloc { [self invalidate]; }

- (BOOL)supported { return !_invalidated && [_entry isSupported]; }
- (BOOL)ready { return !_invalidated && [_entry isReady]; }
- (nullable NSString *)error {
    return [_entry errorText];
}
- (NSDictionary<NSString *, id> *)diagnostics {
    return _entry ? _entry.snapshot : @{@"supported": @NO, @"ready": @NO, @"ranges": @[]};
}

- (void)requestAnalysisAtTime:(CMTime)position bufferedUntil:(CMTime)end {
    if (_invalidated) return;
    if (!_publishedInitialState) {
        _publishedInitialState = YES;
        BStreamSilenceAnalysisEntry *entry = _entry;
        dispatch_async(dispatch_get_main_queue(), ^{ [self entryDidChange:entry]; });
    }
    [_entry requestAt:BStreamSeconds(position) bufferedUntil:BStreamSeconds(end) observer:self];
}

- (CMTime)gapEndForTime:(CMTime)time {
    NSValue *value = [self nextGapAfterTime:time];
    if (!value) return kCMTimeInvalid;
    CMTimeRange range = value.CMTimeRangeValue;
    return CMTimeCompare(time, range.start) >= 0 ? CMTimeRangeGetEnd(range) : kCMTimeInvalid;
}

- (nullable NSValue *)nextGapAfterTime:(CMTime)time {
    return _invalidated ? nil : [_entry nextGapAt:BStreamSeconds(time)];
}

- (void)entryDidChange:(BStreamSilenceAnalysisEntry *)entry {
    void (^callback)(void) = self.onStatusChange;
    if (!_invalidated && _entry == entry && callback) callback();
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    [_entry removeObserver:self];
    _entry = nil;
    self.onStatusChange = nil;
    if (_changedForwardBufferDuration) {
        AVPlayerItem *item = _item;
        NSTimeInterval original = _originalForwardBufferDuration;
        NSTimeInterval assigned = _assignedForwardBufferDuration;
        void (^restoreHint)(void) = ^{
            if (item && fabs(item.preferredForwardBufferDuration - assigned) < 0.00001) {
                item.preferredForwardBufferDuration = original;
            }
        };
        if (NSThread.isMainThread) restoreHint();
        else dispatch_async(dispatch_get_main_queue(), restoreHint);
    }
    _item = nil;
}

@end
