#import "./include/just_audio/BetterEventChannel.h"
#import "./include/just_audio/AudioPlayer.h"
#import "./include/just_audio/AudioSource.h"
#import "./include/just_audio/IndexedAudioSource.h"
#import "./include/just_audio/LoadControl.h"
#import "./include/just_audio/UriAudioSource.h"
#import "./include/just_audio/ConcatenatingAudioSource.h"
#import "./include/just_audio/LoopingAudioSource.h"
#import "./include/just_audio/ClippingAudioSource.h"
#import "./include/just_audio/BStreamAudioProcessingTap.h"
#import "./include/just_audio/BStreamAudioDSP.h"
#import "./include/just_audio/BStreamAudioStatus.h"
#import "./include/just_audio/BStreamSilenceAnalyzer.h"
#import <AVFoundation/AVFoundation.h>
#import <stdlib.h>
#include <math.h>
#include <TargetConditionals.h>

#define TREADMILL_SIZE 2
#define ERROR_ABORT 10000000

// TODO: Check for and report invalid state transitions.
// TODO: Apply Apple's guidance on seeking: https://developer.apple.com/library/archive/qa/qa1820/_index.html
@implementation AudioPlayer {
    NSObject<FlutterPluginRegistrar>* _registrar;
    FlutterMethodChannel *_methodChannel;
    BetterEventChannel *_eventChannel;
    BetterEventChannel *_dataEventChannel;
    NSString *_playerId;
    AVQueuePlayer *_player;
    AudioSource *_audioSource;
    NSMutableArray<IndexedAudioSource *> *_indexedAudioSources;
    NSArray<NSNumber *> *_order;
    NSMutableArray<NSNumber *> *_orderInv;
    int _index;
    enum ProcessingState _processingState;
    enum LoopMode _loopMode;
    BOOL _shuffleModeEnabled;
    long long _updateTime;
    int _updatePosition;
    int _lastPosition;
    int _bufferedPosition;
    // Set when the current item hasn't been played yet so we aren't sure whether sufficient audio has been buffered.
    BOOL _bufferUnconfirmed;
    CMTime _seekPos;
    FlutterResult _loadResult;
    FlutterResult _playResult;
    id _timeObserver;
    BOOL _automaticallyWaitsToMinimizeStalling;
    BOOL _allowsExternalPlayback;
    LoadControl *_loadControl;
    BOOL _useLazyPreparation;
    BOOL _playing;
    float _speed;
    float _volume;
    BOOL _justAdvanced;
    BOOL _enqueuedAll;
    NSDictionary<NSString *, NSObject *> *_icyMetadata;
    NSNumber *_errorCode;
    NSString *_errorMessage;
    BOOL _bstreamRegistered;
    BOOL _bstreamEqualizerEnabled;
    BOOL _bstreamSkipSilenceEnabled;
    BOOL _bstreamDisposed;
    BOOL _bstreamSkipSeeking;
    BOOL _bstreamWaitingForTap;
    NSArray<NSNumber *> *_bstreamGains;
    double _bstreamPreampDb;
    uint64_t _bstreamRevision;
    uint64_t _bstreamSkipEpoch;
    uint64_t _bstreamSkipCount;
    NSUInteger _bstreamSkipFailures;
    NSTimeInterval _bstreamSkipRetryAfter;
    NSMapTable<AVPlayerItem *, BStreamAudioProcessingTap *> *_bstreamProcessors;
    NSMapTable<AVPlayerItem *, BStreamSilenceAnalyzer *> *_bstreamAnalyzers;
    id _bstreamTimeObserver;
    id _bstreamBoundaryObserver;
    __weak AVPlayerItem *_bstreamBoundaryItem;
    CMTime _bstreamBoundaryTime;
    NSDictionary *_bstreamLastStatusSummary;
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam loadConfiguration:(NSDictionary *)loadConfiguration audioEffects:(NSArray *)audioEffects useLazyPreparation:(BOOL)useLazyPreparation {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _playerId = idParam;
    _useLazyPreparation = useLazyPreparation;
    _methodChannel =
        [FlutterMethodChannel methodChannelWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.methods.%@", _playerId]
                                    binaryMessenger:[registrar messenger]];
    _eventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.events.%@", _playerId]
           messenger:[registrar messenger]];
    _dataEventChannel = [[BetterEventChannel alloc]
        initWithName:[NSMutableString stringWithFormat:@"com.ryanheise.just_audio.data.%@", _playerId]
           messenger:[registrar messenger]];
    _index = 0;
    _processingState = psIdle;
    _loopMode = lmLoopOff;
    _shuffleModeEnabled = NO;
    _player = nil;
    _audioSource = nil;
    _indexedAudioSources = nil;
    _order = nil;
    _orderInv = nil;
    _seekPos = kCMTimeInvalid;
    _timeObserver = 0;
    _updatePosition = 0;
    _updateTime = 0;
    _lastPosition = 0;
    _bufferedPosition = 0;
    _bufferUnconfirmed = NO;
    _playing = NO;
    _loadResult = nil;
    _playResult = nil;
    _automaticallyWaitsToMinimizeStalling = YES;
    _allowsExternalPlayback = NO;
    _loadControl = nil;
    if (loadConfiguration != (id)[NSNull null]) {
        NSDictionary *map = loadConfiguration[@"darwinLoadControl"];
        if (map != (id)[NSNull null]) {
            _loadControl = [[LoadControl alloc] init];
            _loadControl.preferredForwardBufferDuration = (NSNumber *)map[@"preferredForwardBufferDuration"];
            _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = (BOOL)[map[@"canUseNetworkResourcesForLiveStreamingWhilePaused"] boolValue];
            _loadControl.preferredPeakBitRate = (NSNumber *)map[@"preferredPeakBitRate"];
            _automaticallyWaitsToMinimizeStalling = (BOOL)[map[@"automaticallyWaitsToMinimizeStalling"] boolValue];
        }
    }
    if (!_loadControl) {
        _loadControl = [[LoadControl alloc] init];
        _loadControl.preferredForwardBufferDuration = (NSNumber *)[NSNull null];
        _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = NO;
        _loadControl.preferredPeakBitRate = (NSNumber *)[NSNull null];
    }
    _speed = 1.0f;
    _volume = 1.0f;
    _justAdvanced = NO;
    _enqueuedAll = NO;
    _icyMetadata = @{};
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    _bstreamProcessors = [NSMapTable weakToStrongObjectsMapTable];
    _bstreamAnalyzers = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray<NSNumber *> *initialGains = [NSMutableArray arrayWithCapacity:BSTREAM_DSP_BANDS];
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) [initialGains addObject:@0];
    _bstreamGains = initialGains.copy;
    _bstreamBoundaryTime = kCMTimeInvalid;
    for (NSDictionary *effect in audioEffects) {
        if ([effect[@"type"] isEqual:@"bstreamAudioEqualizer"]) {
            _bstreamRegistered = YES;
            [self bstreamConfigureEqualizer:effect];
        }
    }
    __weak __typeof__(self) weakSelf = self;
    [_methodChannel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
        [weakSelf handleMethodCall:call result:result];
    }];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    @try {
        //NSLog(@"method: %@ index=%d", call.method, _index);
        NSDictionary *request = (NSDictionary *)call.arguments;
        if ([@"load" isEqualToString:call.method]) {
            CMTime initialPosition = request[@"initialPosition"] == (id)[NSNull null] ? kCMTimeInvalid : CMTimeMake([request[@"initialPosition"] longLongValue], 1000000);
            [self load:request[@"audioSource"] initialPosition:initialPosition initialIndex:request[@"initialIndex"] result:result];
        } else if ([@"play" isEqualToString:call.method]) {
            [self play:result];
        } else if ([@"pause" isEqualToString:call.method]) {
            [self pause];
            result(@{});
        } else if ([@"setVolume" isEqualToString:call.method]) {
            [self setVolume:(float)[request[@"volume"] doubleValue]];
            result(@{});
        } else if ([@"setSkipSilence" isEqualToString:call.method]) {
            _bstreamSkipSilenceEnabled = [request[@"enabled"] boolValue];
            _bstreamSkipFailures = 0;
            _bstreamSkipRetryAfter = 0;
            [self bstreamCancelScheduledSkip];
            if (!_bstreamSkipSilenceEnabled) {
                for (BStreamSilenceAnalyzer *analyzer in _bstreamAnalyzers.objectEnumerator) [analyzer invalidate];
                [_bstreamAnalyzers removeAllObjects];
            }
            [self bstreamProcessingTick];
            [self bstreamPublishStatus];
            result(@{});
        } else if ([@"bstreamEqualizerConfigure" isEqualToString:call.method]) {
            [self bstreamConfigureEqualizer:request];
            result([self bstreamEqualizerStatus]);
            [self bstreamPublishStatus];
        } else if ([@"bstreamEqualizerReadStatus" isEqualToString:call.method]) {
            result([self bstreamEqualizerStatus]);
        } else if ([@"bstreamSkipSilenceReadStatus" isEqualToString:call.method]) {
            result([self bstreamSkipSilenceStatus]);
        } else if ([@"setSpeed" isEqualToString:call.method]) {
            [self setSpeed:(float)[request[@"speed"] doubleValue]];
            result(@{});
        } else if ([@"setLoopMode" isEqualToString:call.method]) {
            [self setLoopMode:[request[@"loopMode"] intValue]];
            result(@{});
        } else if ([@"setShuffleMode" isEqualToString:call.method]) {
            [self setShuffleModeEnabled:(BOOL)([request[@"shuffleMode"] intValue] == 1)];
            result(@{});
        } else if ([@"setShuffleOrder" isEqualToString:call.method]) {
            [self setShuffleOrder:(NSDictionary *)request[@"audioSource"]];
            result(@{});
        } else if ([@"setAutomaticallyWaitsToMinimizeStalling" isEqualToString:call.method]) {
            [self setAutomaticallyWaitsToMinimizeStalling:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setCanUseNetworkResourcesForLiveStreamingWhilePaused" isEqualToString:call.method]) {
            [self setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)[request[@"enabled"] boolValue]];
            result(@{});
        } else if ([@"setPreferredPeakBitRate" isEqualToString:call.method]) {
            [self setPreferredPeakBitRate:(NSNumber *)request[@"bitRate"]];
            result(@{});
        } else if ([@"setAllowsExternalPlayback" isEqualToString:call.method]) {
            [self setAllowsExternalPlayback:(BOOL)([request[@"allowsExternalPlayback"] intValue] == 1)];
            result(@{});
        } else if ([@"seek" isEqualToString:call.method]) {
            CMTime position = request[@"position"] == (id)[NSNull null] ? kCMTimePositiveInfinity : CMTimeMake([request[@"position"] longLongValue], 1000000);
            [self seek:position index:request[@"index"] completionHandler:^(BOOL finished) {
                result(@{});
            }];
        } else if ([@"concatenatingInsertAll" isEqualToString:call.method]) {
            [self concatenatingInsertAll:(NSString *)request[@"id"] index:[request[@"index"] intValue] sources:(NSArray *)request[@"children"] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingRemoveRange" isEqualToString:call.method]) {
            [self concatenatingRemoveRange:(NSString *)request[@"id"] start:[request[@"startIndex"] intValue] end:[request[@"endIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"concatenatingMove" isEqualToString:call.method]) {
            [self concatenatingMove:(NSString *)request[@"id"] currentIndex:[request[@"currentIndex"] intValue] newIndex:[request[@"newIndex"] intValue] shuffleOrder:(NSArray<NSNumber *> *)request[@"shuffleOrder"]];
            result(@{});
        } else if ([@"setAndroidAudioAttributes" isEqualToString:call.method]) {
            result(@{});
        } else {
            result(FlutterMethodNotImplemented);
        }
    } @catch (NSException *exception) {
        //NSLog(@"%@", [exception callStackSymbols]);
        FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Error in handleMethodCall" details:nil];
        result(flutterError);
    }
}

- (AVQueuePlayer *)player {
    return _player;
}

- (float)speed {
    return _speed;
}

- (void)bstreamConfigureEqualizer:(NSDictionary *)request {
    NSArray *raw = request[@"gainsDb"];
    if (![raw isKindOfClass:[NSArray class]] || raw.count != BSTREAM_DSP_BANDS) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Ten equalizer gains are required" userInfo:nil];
    }
    NSMutableArray<NSNumber *> *gains = [NSMutableArray arrayWithCapacity:BSTREAM_DSP_BANDS];
    for (id value in raw) {
        if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue])) {
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Equalizer gains must be finite" userInfo:nil];
        }
        [gains addObject:@(fmax(-12, fmin(12, [value doubleValue])))];
    }
    BOOL enabled = [request[@"enabled"] boolValue];
    if (enabled != _bstreamEqualizerEnabled || ![_bstreamGains isEqualToArray:gains]) ++_bstreamRevision;
    _bstreamGains = gains.copy;
    double nativeGains[BSTREAM_DSP_BANDS];
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) nativeGains[i] = gains[i].doubleValue;
    _bstreamPreampDb = BStreamDSPHeadroomDb(nativeGains);
    _bstreamEqualizerEnabled = enabled;
    for (AVPlayerItem *item in _player.items) {
        BStreamAudioProcessingTap *processor = [_bstreamProcessors objectForKey:item];
        [processor configureEnabled:enabled gains:_bstreamGains revision:_bstreamRevision];
    }
}

- (BStreamSilenceAnalyzer *)bstreamAnalyzerForItem:(AVPlayerItem *)item {
    if (!item || !_bstreamSkipSilenceEnabled || _bstreamDisposed) return nil;
    BStreamSilenceAnalyzer *analyzer = [_bstreamAnalyzers objectForKey:item];
    if (!analyzer) {
        analyzer = [[BStreamSilenceAnalyzer alloc] initWithItem:item];
        [_bstreamAnalyzers setObject:analyzer forKey:item];
        __weak AudioPlayer *weakSelf = self;
        __weak AVPlayerItem *weakItem = item;
        analyzer.onStatusChange = ^{
            AudioPlayer *owner = weakSelf;
            if (!owner || owner->_bstreamDisposed || owner->_player.currentItem != weakItem) return;
            [owner bstreamPublishStatus];
            [owner bstreamProcessingTick];
        };
    }
    return analyzer;
}

- (void)bstreamAttachProcessingToItem:(AVPlayerItem *)item {
    if (!item || !_bstreamRegistered || _bstreamDisposed) return;
    BStreamAudioProcessingTap *existing = [_bstreamProcessors objectForKey:item];
    if (existing) {
        [existing configureEnabled:_bstreamEqualizerEnabled gains:_bstreamGains revision:_bstreamRevision];
        [existing configureOutputVolume:_volume enabled:existing.supported && !_player.externalPlaybackActive];
        [existing cancelFade];
        return;
    }
    BStreamAudioProcessingTap *processor = [[BStreamAudioProcessingTap alloc] initWithItem:item];
    if (!processor) return;
    [_bstreamProcessors setObject:processor forKey:item];
    [processor configureEnabled:_bstreamEqualizerEnabled gains:_bstreamGains revision:_bstreamRevision];
    [processor configureOutputVolume:_volume enabled:!_player.externalPlaybackActive];
    __weak AudioPlayer *weakSelf = self;
    __weak AVPlayerItem *weakItem = item;
    processor.onStatusChange = ^{
        AudioPlayer *owner = weakSelf;
        if (!owner || owner->_bstreamDisposed || owner->_player.currentItem != weakItem) return;
        [owner bstreamApplyVolume];
        [owner bstreamPublishStatus];
        [owner bstreamApplyPlaybackRate];
    };
}

- (void)bstreamApplyVolume {
    if (!_player) return;
    BOOL external = _player.externalPlaybackActive;
    BStreamAudioProcessingTap *current = [_bstreamProcessors objectForKey:_player.currentItem];
    BOOL usesTap = _bstreamRegistered && current.supported && current.outputVolumeSupported && !external;
    // Restore the native attenuation before releasing tap ownership. Transfer
    // back only after the atomic gain is initialized, never with two unity gains.
    if (!usesTap && _player.volume != _volume) _player.volume = _volume;
    for (BStreamAudioProcessingTap *processor in _bstreamProcessors.objectEnumerator) {
        // Prime queued/pending taps before their first frame, including mute.
        // Failed routes acknowledge native ownership immediately.
        BOOL ownsGain = _bstreamRegistered && processor.supported && !external;
        [processor configureOutputVolume:_volume enabled:ownsGain];
    }
    if (usesTap && _player.volume != 1) _player.volume = 1;
}

- (NSDictionary *)bstreamEqualizerStatus {
    AVPlayerItem *item = _player.currentItem;
    BStreamAudioProcessingTap *processor = item ? [_bstreamProcessors objectForKey:item] : nil;
    BOOL external = _player && _player.externalPlaybackActive;
    BOOL supported = _bstreamRegistered && !external && (!item || processor.supported);
    BOOL active = NO;
    NSMutableArray *bands = [NSMutableArray arrayWithCapacity:BSTREAM_DSP_BANDS];
    for (int i = 0; i < BSTREAM_DSP_BANDS; i++) {
        double gain = _bstreamGains[i].doubleValue;
        active |= fabs(gain) >= .01;
        [bands addObject:@{@"index": @(i), @"centerFrequency": @(BStreamDSPFrequencies[i]), @"gain": @(gain)}];
    }
    active = supported && _bstreamEqualizerEnabled && active;
    NSMutableDictionary *status = processor ? [[processor diagnostics] mutableCopy] : [NSMutableDictionary dictionary];
    status[@"supported"] = @(supported);
    status[@"configured"] = BStreamAudioStatusBoolean(processor && processor.configured);
    status[@"enabled"] = @(active);
    status[@"engine"] = @"bstream-dsp";
    status[@"preampDb"] = @(active ? _bstreamPreampDb : 0);
    status[@"revision"] = @(_bstreamRevision);
    status[@"parameters"] = @{@"minDecibels": @(-12), @"maxDecibels": @12, @"bands": bands};
    BStreamSilenceAnalyzer *analyzer = item ? [_bstreamAnalyzers objectForKey:item] : nil;
    if (analyzer) status[@"skipSilenceSupported"] = BStreamAudioStatusBoolean(analyzer.supported && !external && _bstreamSkipFailures < 3);
    else if (external) status[@"skipSilenceSupported"] = @NO;
    return status;
}

- (NSDictionary *)bstreamSkipSilenceStatus {
    BStreamSilenceAnalyzer *analyzer = _player.currentItem ? [_bstreamAnalyzers objectForKey:_player.currentItem] : nil;
    NSMutableDictionary *status = analyzer ? [analyzer.diagnostics mutableCopy] : [NSMutableDictionary dictionary];
    status[@"requestedEnabled"] = @(_bstreamSkipSilenceEnabled);
    status[@"supported"] = BStreamAudioStatusBoolean((!analyzer || analyzer.supported) && _bstreamSkipFailures < 3 && !_player.externalPlaybackActive);
    status[@"seekCount"] = @(_bstreamSkipCount);
    return status;
}

- (void)bstreamPublishStatus {
    if (!_bstreamRegistered || _bstreamDisposed) return;
    NSDictionary *status = [self bstreamEqualizerStatus];
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"supported", @"skipSilenceSupported", @"configured", @"sampleRate",
                            @"channelCount", @"pcmEncoding", @"enabled", @"revision", @"error"]) {
        summary[key] = status[key] ?: (id)[NSNull null];
    }
    if ([_bstreamLastStatusSummary isEqualToDictionary:summary]) return;
    _bstreamLastStatusSummary = summary.copy;
    [_methodChannel invokeMethod:@"bstreamEqualizerStatusChanged" arguments:status];
}

- (void)bstreamApplyPlaybackRate {
    if (!_playing || !_player || _bstreamDisposed || _processingState == psCompleted) return;
    BStreamAudioProcessingTap *processor = [_bstreamProcessors objectForKey:_player.currentItem];
    // Loading tracks and installing the initial mix precede audibility. Preset
    // changes never replace the mix and cannot restart AVPlayer's media clock.
    if (processor && !processor.ready) {
        BOOL beganWaiting = !_bstreamWaitingForTap;
        _bstreamWaitingForTap = YES;
        _player.rate = 0;
        if (beganWaiting && _processingState != psLoading && _processingState != psCompleted) {
            // Dart may extrapolate a ready+playing clock while AVPlayer is
            // deliberately held at zero. Publish the real preparation wait.
            [self enterBuffering:@"waiting for audio processing installation"];
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
        return;
    }
    _bstreamWaitingForTap = NO;
    if (_bstreamRegistered && _processingState == psReady && _player.currentItem) {
        if (@available(macOS 10.12, iOS 10.0, *)) {
            if (_player.timeControlStatus != AVPlayerTimeControlStatusPlaying) {
                // An already installed tap does not mean AVPlayer has begun
                // advancing. Publish the wait before requesting its rate.
                [self enterBuffering:@"waiting for playback to start"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            }
        }
    }
    // AVPlayer's normal timeControlStatus callback exits buffering once it
    // actually plays. Do not claim readiness over a network-buffering wait.
    _player.rate = _speed;
}

- (void)bstreamCancelScheduledSkip {
    ++_bstreamSkipEpoch;
    if (_bstreamSkipSeeking) [_player.currentItem cancelPendingSeeks];
    _bstreamSkipSeeking = NO;
    if (_bstreamBoundaryObserver) {
        [_player removeTimeObserver:_bstreamBoundaryObserver];
        _bstreamBoundaryObserver = nil;
    }
    [[_bstreamProcessors objectForKey:_bstreamBoundaryItem] cancelFade];
    _bstreamBoundaryItem = nil;
    _bstreamBoundaryTime = kCMTimeInvalid;
    for (AVPlayerItem *item in _player.items) [[_bstreamProcessors objectForKey:item] cancelFade];
}

- (void)bstreamEnsureTimeObserver {
    if (!_player || _bstreamTimeObserver || _bstreamDisposed || (!_bstreamRegistered && !_bstreamSkipSilenceEnabled)) return;
    __weak AudioPlayer *weakSelf = self;
    _bstreamTimeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(200, 1000)
        queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            [weakSelf bstreamProcessingTick];
        }];
}

- (void)bstreamPerformSkipForItem:(AVPlayerItem *)item expectedEpoch:(uint64_t)epoch {
    if (!item || _bstreamDisposed || !_bstreamSkipSilenceEnabled || !_playing ||
        item != _player.currentItem || epoch != _bstreamSkipEpoch ||
        _player.externalPlaybackActive || _bstreamSkipFailures >= 3 ||
        NSProcessInfo.processInfo.systemUptime < _bstreamSkipRetryAfter ||
        CMTIME_IS_VALID(_seekPos) || _bstreamSkipSeeking) return;
    BStreamSilenceAnalyzer *analyzer = [_bstreamAnalyzers objectForKey:item];
    CMTime now = item.currentTime;
    if (!analyzer) return;
    CMTime target = [analyzer gapEndForTime:now];
    if (!CMTIME_IS_NUMERIC(target)) return;
    CMTime clipEnd = item.forwardPlaybackEndTime;
    if (CMTIME_IS_NUMERIC(clipEnd) && CMTimeCompare(target, clipEnd) >= 0) {
        // Leave the final retained samples for AVQueuePlayer's natural EOF and
        // the existing crossfade/promotion logic; never seek to the next song.
        target = CMTimeSubtract(clipEnd, CMTimeMake(250, 1000));
    }
    if (CMTimeGetSeconds(CMTimeSubtract(target, now)) < .08) return;
    _bstreamSkipSeeking = YES;
    if (_bstreamBoundaryObserver) {
        [_player removeTimeObserver:_bstreamBoundaryObserver];
        _bstreamBoundaryObserver = nil;
    }
    _bstreamBoundaryItem = nil;
    BStreamAudioProcessingTap *processor = [_bstreamProcessors objectForKey:item];
    [processor resetAfterSeekToTime:target fadeIn:YES];
    __weak AudioPlayer *weakSelf = self;
    [item seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AudioPlayer *owner = weakSelf;
            if (!owner || owner->_bstreamDisposed || item != owner->_player.currentItem || epoch != owner->_bstreamSkipEpoch) return;
            owner->_bstreamSkipSeeking = NO;
            if (finished && owner->_bstreamSkipSilenceEnabled) {
                ++owner->_bstreamSkipCount;
                owner->_bstreamSkipFailures = 0;
                owner->_bstreamSkipRetryAfter = 0;
                [owner updatePosition];
                [owner broadcastPlaybackEvent];
            } else {
                ++owner->_bstreamSkipFailures;
                owner->_bstreamSkipRetryAfter = NSProcessInfo.processInfo.systemUptime + 1;
                [processor cancelFade];
                [owner bstreamPublishStatus];
            }
            [owner bstreamProcessingTick];
        });
    }];
}

- (void)bstreamProcessingTick {
    if (_bstreamDisposed || !_player) return;
    [self bstreamEnsureTimeObserver];
    AVPlayerItem *item = _player.currentItem;
    if (!item) return;
    BStreamAudioProcessingTap *processor = [_bstreamProcessors objectForKey:item];
    if (_playing && _player.rate > 0 && CMTIME_IS_INVALID(_seekPos) && !_bstreamSkipSeeking) {
        [processor validatePlaybackAtTime:item.currentTime];
    }
    if ([processor consumeStatusChange]) {
        [self bstreamApplyVolume];
        [self bstreamPublishStatus];
    }
    if (_player.externalPlaybackActive) {
        [self bstreamCancelScheduledSkip];
        return;
    }
    if (!_bstreamSkipSilenceEnabled || _player.externalPlaybackActive ||
        item.status != AVPlayerItemStatusReadyToPlay || _bstreamSkipSeeking || CMTIME_IS_VALID(_seekPos)) return;
    if (_bstreamSkipFailures >= 3) return;
    BStreamSilenceAnalyzer *analyzer = [self bstreamAnalyzerForItem:item];
    if (!analyzer.supported) return;
    CMTime now = item.currentTime;
    if (!CMTIME_IS_NUMERIC(now)) return;
    CMTime bufferedUntil = now;
    for (NSValue *value in item.loadedTimeRanges) {
        CMTimeRange range = value.CMTimeRangeValue;
        if (CMTimeRangeContainsTime(range, now) || CMTimeCompare(now, CMTimeRangeGetEnd(range)) == 0) {
            bufferedUntil = CMTimeRangeGetEnd(range);
            break;
        }
    }
    [analyzer requestAnalysisAtTime:now bufferedUntil:bufferedUntil];
    if (!_playing) return; // A prepared deck may analyze without becoming audible.
    NSValue *next = [analyzer nextGapAfterTime:now];
    if (!next) return;
    CMTimeRange gap = next.CMTimeRangeValue;
    CMTime clipEnd = item.forwardPlaybackEndTime;
    if (CMTIME_IS_NUMERIC(clipEnd) && CMTimeCompare(gap.start, clipEnd) >= 0) return;
    if (CMTimeCompare(now, gap.start) >= 0) {
        [self bstreamPerformSkipForItem:item expectedEpoch:_bstreamSkipEpoch];
        return;
    }
    if (_bstreamBoundaryObserver && _bstreamBoundaryItem == item && CMTimeCompare(_bstreamBoundaryTime, gap.start) == 0) return;
    [self bstreamCancelScheduledSkip];
    _bstreamBoundaryItem = item;
    _bstreamBoundaryTime = gap.start;
    [processor fadeOutAtTime:gap.start];
    uint64_t epoch = _bstreamSkipEpoch;
    __weak AudioPlayer *weakSelf = self;
    __weak AVPlayerItem *weakItem = item;
    _bstreamBoundaryObserver = [_player addBoundaryTimeObserverForTimes:@[[NSValue valueWithCMTime:gap.start]]
        queue:dispatch_get_main_queue() usingBlock:^{
            [weakSelf bstreamPerformSkipForItem:weakItem expectedEpoch:epoch];
        }];
}

// Untested
- (void)concatenatingInsertAll:(NSString *)catId index:(int)index sources:(NSArray *)sources shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Add each new source to each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int idx = index >= 0 ? index : catSource.count;
        NSMutableArray<AudioSource *> *audioSources = [self decodeAudioSources:sources];
        for (int j = 0; j < audioSources.count; j++) {
            AudioSource *audioSource = audioSources[j];
            [catSource insertSource:audioSource atIndex:(idx + j)];
        }
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Index the new audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        if (!audioSource.isAttached) {
            audioSource.playerItem.audioSource = audioSource;
            [self addItemObservers:audioSource.playerItem];
        }
    }
    [self updateOrder];
    if (_player.currentItem) {
        _index = [self indexForItem:(IndexedPlayerItem *)_player.currentItem];
    } else {
        _index = 0;
    }
    [self enqueueFrom:_index];
    // Notify each new IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        if (!_indexedAudioSources[i].isAttached) {
            [_indexedAudioSources[i] attach:_player initialPos:kCMTimeInvalid];
        }
    }
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingRemoveRange:(NSString *)catId start:(int)start end:(int)end shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Remove range from each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        int endIndex = end >= 0 ? end : catSource.count;
        [catSource removeSourcesFromIndex:start toIndex:endIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the remaining audio sources.
    NSArray<IndexedAudioSource *> *oldIndexedAudioSources = _indexedAudioSources;
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0, j = 0; i < _indexedAudioSources.count; i++, j++) {
        IndexedAudioSource *audioSource = _indexedAudioSources[i];
        while (audioSource != oldIndexedAudioSources[j]) {
            [self removeItemObservers:oldIndexedAudioSources[j].playerItem];
            if (oldIndexedAudioSources[j].playerItem2) {
                [self removeItemObservers:oldIndexedAudioSources[j].playerItem2];
            }
            if (j < _index) {
                _index--;
            } else if (j == _index) {
                // The currently playing item was removed.
            }
            j++;
        }
    }
    [self updateOrder];
    if (_index >= _indexedAudioSources.count) _index = (int)_indexedAudioSources.count - 1;
    if (_index < 0) _index = 0;
    [self enqueueFrom:_index];
    [self broadcastPlaybackEvent];
}

// Untested
- (void)concatenatingMove:(NSString *)catId currentIndex:(int)currentIndex newIndex:(int)newIndex shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder {
    // Find all duplicates of the identified ConcatenatingAudioSource.
    NSMutableArray *matches = [[NSMutableArray alloc] init];
    [_audioSource findById:catId matches:matches];
    // Move range within each match.
    for (int i = 0; i < matches.count; i++) {
        ConcatenatingAudioSource *catSource = (ConcatenatingAudioSource *)matches[i];
        [catSource moveSourceFromIndex:currentIndex toIndex:newIndex];
        [catSource setShuffleOrder:shuffleOrder];
    }
    // Re-index the audio sources.
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    [self updateOrder];
    [self enqueueFrom:[self indexForItem:(IndexedPlayerItem *)_player.currentItem]];
    [self broadcastPlaybackEvent];
}

- (void)checkForDiscontinuity {
    if (!_playing || CMTIME_IS_VALID(_seekPos) || _processingState == psCompleted) return;
    int position = [self getCurrentPosition];
    if (_processingState == psBuffering) {
        if (position > _lastPosition) {
            [self leaveBuffering:@"stall ended"];
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    } else {
        long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
        long long timeSinceLastUpdate = now - _updateTime;
        long long expectedPosition = _updatePosition + (long long)(timeSinceLastUpdate * _player.rate);
        long long drift = position - expectedPosition;
        //NSLog(@"position: %d, drift: %lld", position, drift);
        // Update if we've drifted or just started observing
        if (_updateTime == 0L) {
            [self broadcastPlaybackEvent];
        } else if (drift < -100) {
            [self enterBuffering:@"stalling"];
            //NSLog(@"Drift: %lld", drift);
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    }
    _lastPosition = position;
}

- (void)enterBuffering:(NSString *)reason {
    if (_processingState != psIdle) {
        //NSLog(@"ENTER BUFFERING: %@", reason);
        _processingState = psBuffering;
    }
}

- (void)leaveBuffering:(NSString *)reason {
    if (_bstreamWaitingForTap && _playing) return;
    if (_bstreamRegistered && _playing && _player.currentItem) {
        if (@available(macOS 10.12, iOS 10.0, *)) {
            // Readiness of the item is distinct from its clock actually running.
            // Only AVPlayer's Playing state releases a pending play intent.
            if (_player.timeControlStatus != AVPlayerTimeControlStatusPlaying) return;
        }
    }
    if (_processingState == psBuffering || _processingState == psLoading) {
        //NSLog(@"LEAVE BUFFERING: %@", reason);
        _processingState = psReady;
    }
}

- (void)broadcastPlaybackEvent {
    [_eventChannel sendEvent:@{
            @"processingState": @(_processingState),
            @"updatePosition": @((long long)1000 * _updatePosition),
            @"updateTime": @(_updateTime),
            @"bufferedPosition": @((long long)1000 * [self getBufferedPosition]),
            @"icyMetadata": _icyMetadata,
            @"duration": @([self getDurationMicroseconds]),
            @"currentIndex": @(_index),
            @"errorCode": _errorCode,
            @"errorMessage": _errorMessage,
    }];
}

- (int)getCurrentPosition {
    // XXX: During load, the second case will be selected returning 0.
    // TODO: Provide a similar case as _seekPos for _initialPos.
    if (CMTIME_IS_VALID(_seekPos)) {
        return (int)(1000 * CMTimeGetSeconds(_seekPos));
    } else if (_index >= 0 && (NSUInteger)_index < _indexedAudioSources.count) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].position));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getBufferedPosition {
    if (_processingState == psIdle || _processingState == psLoading) {
        return 0;
    } else if (_index >= 0 && (NSUInteger)_index < _indexedAudioSources.count) {
        int ms = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].bufferedPosition));
        if (ms < 0) ms = 0;
        return ms;
    } else {
        return 0;
    }
}

- (int)getDuration {
    if (_processingState == psIdle || _processingState == psLoading) {
        return -1;
    } else if (_index >= 0 && (NSUInteger)_index < _indexedAudioSources.count) {
        int v = (int)(1000 * CMTimeGetSeconds(_indexedAudioSources[_index].duration));
        return v;
    } else {
        return 0;
    }
}

- (long long)getDurationMicroseconds {
    int duration = [self getDuration];
    return duration < 0 ? -1 : ((long long)1000 * duration);
}

- (void)removeItemObservers:(AVPlayerItem *)playerItem {
    [[_bstreamProcessors objectForKey:playerItem] invalidate];
    [[_bstreamAnalyzers objectForKey:playerItem] invalidate];
    [_bstreamProcessors removeObjectForKey:playerItem];
    [_bstreamAnalyzers removeObjectForKey:playerItem];
    [playerItem removeObserver:self forKeyPath:@"status"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferEmpty"];
    [playerItem removeObserver:self forKeyPath:@"playbackBufferFull"];
    [playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
    //[playerItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:playerItem];
}

- (void)addItemObservers:(AVPlayerItem *)playerItem {
    // Get notified when the item is loaded or had an error loading
    [playerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified of the buffer state
    [playerItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"playbackBufferFull" options:NSKeyValueObservingOptionNew context:nil];
    [playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
    //[playerItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:nil];
    // Get notified when playback has reached the end
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onComplete:) name:AVPlayerItemDidPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stops due to a failure (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onFailToComplete:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:playerItem];
    // Get notified when playback stalls (currently unused)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:playerItem];

    AVPlayerItemMetadataOutput *metadataOutput = [[AVPlayerItemMetadataOutput alloc] initWithIdentifiers:nil];
    [metadataOutput setDelegate:self queue:dispatch_get_main_queue()];
    // Since the delegate is stored as a weak reference,
    // there shouldn't be a retain cycle.
    // TODO: Check this. Shouldn't need to removeOutput
    // later?
    [playerItem addOutput:metadataOutput];
}

- (void)metadataOutput:(AVPlayerItemMetadataOutput *)output didOutputTimedMetadataGroups:(NSArray<AVTimedMetadataGroup *> *)groups fromPlayerItemTrack:(AVPlayerItemTrack *)track {
    // ICY headers aren't available here. Maybe do this in the proxy.
    BOOL hasIcyData = NO;
    NSString *title = (NSString *)[NSNull null];
    NSString *url = (NSString *)[NSNull null];
    for (int i = 0; i < groups.count; i++) {
        AVTimedMetadataGroup *group = groups[i];
        for (int j = 0; j < group.items.count; j++) {
            AVMetadataItem *item = group.items[j];
            if ([@"icy/StreamTitle" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                title = (NSString *)item.value;
            } else if ([@"icy/StreamUrl" isEqualToString:item.identifier]) {
                hasIcyData = YES;
                url = (NSString *)item.value;
            }
        }
    }
    if (hasIcyData) {
        _icyMetadata = @{
            @"info": @{
                @"title": title,
                @"url": url,
            },
        };
        [self broadcastPlaybackEvent];
    }
}

- (NSMutableArray<AudioSource *> *)decodeAudioSources:(NSArray *)data {
    NSMutableArray<AudioSource *> *array = (NSMutableArray<AudioSource *> *)[[NSMutableArray alloc] init];
    for (int i = 0; i < [data count]; i++) {
        AudioSource *source = [self decodeAudioSource:data[i]];
        [array addObject:source];
    }
    return array;
}

- (AudioSource *)decodeAudioSource:(NSDictionary *)data {
    NSString *type = data[@"type"];
    if ([@"progressive" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"dash" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"hls" isEqualToString:type]) {
        return [[UriAudioSource alloc] initWithId:data[@"id"] uri:data[@"uri"] loadControl:_loadControl headers:data[@"headers"] options:data[@"options"]];
    } else if ([@"concatenating" isEqualToString:type]) {
        return [[ConcatenatingAudioSource alloc] initWithId:data[@"id"]
                                               audioSources:[self decodeAudioSources:data[@"children"]]
                                               shuffleOrder:(NSArray<NSNumber *> *)data[@"shuffleOrder"]
                                                lazyLoading:(NSNumber *)data[@"useLazyPreparation"]];
    } else if ([@"clipping" isEqualToString:type]) {
        return [[ClippingAudioSource alloc] initWithId:data[@"id"]
                                           audioSource:(UriAudioSource *)[self decodeAudioSource:data[@"child"]]
                                                 start:data[@"start"]
                                                   end:data[@"end"]];
    } else if ([@"looping" isEqualToString:type]) {
        NSMutableArray *childSources = [NSMutableArray new];
        int count = [data[@"count"] intValue];
        for (int i = 0; i < count; i++) {
            [childSources addObject:[self decodeAudioSource:data[@"child"]]];
        }
        return [[LoopingAudioSource alloc] initWithId:data[@"id"] audioSources:childSources];
    } else {
        return nil;
    }
}

- (void)enqueueFrom:(int)index {
    //NSLog(@"### enqueueFrom:%d", index);
    _index = index;

    // Update the queue while keeping the currently playing item untouched.

    /* NSLog(@"before reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // First, remove all _player items except for the currently playing one (if any).
    IndexedPlayerItem *oldItem = (IndexedPlayerItem *)_player.currentItem;
    IndexedPlayerItem *existingItem = nil;
    IndexedPlayerItem *newItem = _indexedAudioSources.count > 0 ? _indexedAudioSources[_index].playerItem : nil;
    NSArray *oldPlayerItems = [NSArray arrayWithArray:_player.items];
    // In the first pass, preserve the old and new items.
    // TODO: preserve as much of the treadmill as possible
    for (int i = 0; i < oldPlayerItems.count; i++) {
        if (oldPlayerItems[i] == newItem) {
            // Preserve and tag new item if it is already in the queue.
            existingItem = oldPlayerItems[i];
            //NSLog(@"Preserving existing item %d", [self indexForItem:existingItem]);
        } else if (oldPlayerItems[i] == oldItem) {
            //NSLog(@"Preserving old item %d", [self indexForItem:oldItem]);
            // Temporarily preserve old item, just to avoid jumping to
            // intermediate queue positions unnecessarily. We only want to jump
            // once to _index.
        } else {
            //NSLog(@"Removing item %d", [self indexForItem:oldPlayerItems[i]]);
            [_player removeItem:oldPlayerItems[i]];
        }
    }
    // In the second pass, remove the old item (if different from new item).
    if (oldItem && newItem != oldItem) {
        //NSLog(@"removing old item %d", [self indexForItem:oldItem]);
        [_player removeItem:oldItem];
    }

    /* NSLog(@"inter order: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    // Regenerate queue
    _enqueuedAll = NO;
    if (!existingItem || _loopMode != lmLoopOne) {
        _enqueuedAll = YES;
        BOOL include = NO;
        for (int i = 0; i < [_order count]; i++) {
            int si = [_order[i] intValue];
            if (si == _index) include = YES;
            if (include && _indexedAudioSources[si].playerItem != existingItem) {
                if (_indexedAudioSources[si].lazyLoading && _player.items.count >= TREADMILL_SIZE) {
                    // Enqueue up until the first lazy item that does not fit on the treadmill.
                    _enqueuedAll = NO;
                    break;
                }
                //NSLog(@"inserting item %d", si);
                [self bstreamAttachProcessingToItem:_indexedAudioSources[si].playerItem];
                [_player insertItem:_indexedAudioSources[si].playerItem afterItem:nil];
                if (_loopMode == lmLoopOne) {
                    // We only want one item in the queue.
                    break;
                }
            }
        }
    }

    // Add next loop item if we're looping
    if (_order.count > 0) {
        if (_loopMode == lmLoopAll && _enqueuedAll) {
            int si = [_order[0] intValue];
            //NSLog(@"### add loop item:%d", si);
            if (!_indexedAudioSources[si].playerItem2) {
                [_indexedAudioSources[si] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[si].playerItem2];
            }
            [self bstreamAttachProcessingToItem:_indexedAudioSources[si].playerItem2];
            [_player insertItem:_indexedAudioSources[si].playerItem2 afterItem:nil];
        } else if (_loopMode == lmLoopOne) {
            //NSLog(@"### add loop item:%d", _index);
            if (!_indexedAudioSources[_index].playerItem2) {
                [_indexedAudioSources[_index] preparePlayerItem2];
                [self addItemObservers:_indexedAudioSources[_index].playerItem2];
            }
            [self bstreamAttachProcessingToItem:_indexedAudioSources[_index].playerItem2];
            [_player insertItem:_indexedAudioSources[_index].playerItem2 afterItem:nil];
        }
    }

    /* NSLog(@"after reorder: _player.items.count: ", _player.items.count); */
    /* [self dumpQueue]; */

    if (_processingState != psLoading && oldItem != newItem) {
        // || !_player.currentItem.playbackLikelyToKeepUp;
        if (_player.currentItem.playbackBufferEmpty) {
            [self enterBuffering:@"enqueueFrom playbackBufferEmpty"];
        } else {
            [self leaveBuffering:@"enqueueFrom !playbackBufferEmpty"];
        }
        [self updatePosition];
    }

    [self updateEndAction];
}

- (void)updatePosition {
    _updatePosition = [self getCurrentPosition];
    _updateTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

- (void)load:(NSDictionary *)source initialPosition:(CMTime)initialPosition initialIndex:(NSNumber *)initialIndex result:(FlutterResult)result {
    _bstreamWaitingForTap = NO;
    if (_playing) {
        [_player pause];
    }
    if (_processingState == psLoading) {
        [self abortExistingConnection:NO];
    }
    _loadResult = result;
    _processingState = psLoading;
    _index = (initialIndex != (id)[NSNull null]) ? [initialIndex intValue] : 0;
    _errorCode = (NSNumber *)[NSNull null];
    _errorMessage = (NSString *)[NSNull null];
    // Remove previous observers
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
    }
    // Decode audio source
    if (_audioSource && [@"clipping" isEqualToString:source[@"type"]]) {
        // Check if we're clipping an audio source that was previously loaded.
        UriAudioSource *child = nil;
        if ([_audioSource isKindOfClass:[ClippingAudioSource class]]) {
            ClippingAudioSource *clipper = (ClippingAudioSource *)_audioSource;
            child = clipper.audioSource;
        } else if ([_audioSource isKindOfClass:[UriAudioSource class]]) {
            child = (UriAudioSource *)_audioSource;
        }
        NSString *type = source[@"child"][@"type"];
        NSString *uri = nil;
        if ([@"progressive" isEqualToString:type] || [@"dash" isEqualToString:type] || [@"hls" isEqualToString:type]) {
            uri = source[@"child"][@"uri"];
        }
        if (child && uri && [child.uri isEqualToString:uri]) {
            ClippingAudioSource *clipper =
                [[ClippingAudioSource alloc] initWithId:source[@"id"]
                                            audioSource:child
                                                  start:source[@"start"]
                                                    end:source[@"end"]];
            clipper.playerItem.audioSource = clipper;
            if (clipper.playerItem2) {
                clipper.playerItem2.audioSource = clipper;
            }
            _audioSource = clipper;
        } else {
            _audioSource = [self decodeAudioSource:source];
        }
    } else {
        _audioSource = [self decodeAudioSource:source];
    }
    _indexedAudioSources = [[NSMutableArray alloc] init];
    [_audioSource buildSequence:_indexedAudioSources treeIndex:0];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        IndexedAudioSource *source = _indexedAudioSources[i];
        [self addItemObservers:source.playerItem];
        source.playerItem.audioSource = source;
    }
    [self updatePosition];
    [self updateOrder];
    // Set up an empty player
    if (!_player) {
        _player = [[AVQueuePlayer alloc] initWithItems:@[]];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            _player.automaticallyWaitsToMinimizeStalling = _automaticallyWaitsToMinimizeStalling;
            // TODO: Remove these observers in dispose.
            [_player addObserver:self
                      forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionNew
                         context:nil];
        }
        if (@available(macOS 10.11, iOS 6.0, *)) {
            _player.allowsExternalPlayback = _allowsExternalPlayback;
        }
        [_player addObserver:self
                  forKeyPath:@"currentItem"
                     options:NSKeyValueObservingOptionNew
                     context:nil];
        [_player addObserver:self forKeyPath:@"externalPlaybackActive"
                     options:NSKeyValueObservingOptionNew context:nil];
        // TODO: learn about the different ways to define weakSelf.
        //__weak __typeof__(self) weakSelf = self;
        //typeof(self) __weak weakSelf = self;
        __unsafe_unretained __typeof__(self) weakSelf = self;
        if (@available(macOS 10.12, iOS 10.0, *)) {}
        else {
            _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(200, 1000)
                                                                  queue:nil
                                                             usingBlock:^(CMTime time) {
                                                                 [weakSelf checkForDiscontinuity];
                                                             }
            ];
        }
    }
    [self bstreamEnsureTimeObserver];
    // Initialise the AVQueuePlayer with items.
    [self enqueueFrom:_index];
    // Notify each IndexedAudioSource that it's been attached to the player.
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] attach:_player initialPos:(i == _index ? initialPosition : kCMTimeInvalid)];
    }

    if (_playing) {
        [self bstreamApplyPlaybackRate];
    }
    [self bstreamApplyVolume];
    [self broadcastPlaybackEvent];

    if (_loadResult && (_indexedAudioSources.count == 0 || !_player.currentItem ||
            _player.currentItem.status == AVPlayerItemStatusReadyToPlay)) {
        [self leaveBuffering:@"load ready"];
        _loadResult(@{@"duration": @([self getDurationMicroseconds])});
        _loadResult = nil;
    } else {
        // We send result after the playerItem is ready in observeValueForKeyPath.
    }
    /* NSLog(@"load:"); */
    /* for (int i = 0; i < [_indexedAudioSources count]; i++) { */
    /*     NSLog(@"- %@", _indexedAudioSources[i].sourceId); */
    /* } */
}

- (void)updateOrder {
    _orderInv = [NSMutableArray arrayWithCapacity:[_indexedAudioSources count]];
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_orderInv addObject:@(0)];
    }
    if (_shuffleModeEnabled) {
        _order = [_audioSource getShuffleIndices];
    } else {
        NSMutableArray *order = [[NSMutableArray alloc] init];
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [order addObject:@(i)];
        }
        _order = order;
    }
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        _orderInv[[_order[i] intValue]] = @(i);
    }
}

- (void)onItemStalled:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onItemStalled");
}

- (void)onFailToComplete:(NSNotification *)notification {
    //IndexedPlayerItem *playerItem = (IndexedPlayerItem *)notification.object;
    //NSLog(@"onFailToComplete");
}

- (void)onComplete:(NSNotification *)notification {
    //NSLog(@"onComplete");

    IndexedPlayerItem *endedPlayerItem = (IndexedPlayerItem *)notification.object;
    IndexedAudioSource *endedSource = endedPlayerItem.audioSource;

    if (_loopMode == lmLoopOne) {
        [endedSource seek:kCMTimeZero];
        _justAdvanced = YES;
    } else if (_loopMode == lmLoopAll) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1) % _order.count] intValue];
        [self updatePosition];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else if ([_orderInv[_index] intValue] + 1 < [_order count]) {
        [endedSource seek:kCMTimeZero];
        _index = [_order[([_orderInv[_index] intValue] + 1)] intValue];
        [self updateEndAction];
        [self updatePosition];
        [self broadcastPlaybackEvent];
        _justAdvanced = YES;
    } else {
        // reached end of playlist
        [self complete];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSString *,id> *)change
                       context:(void *)context {

    if ([keyPath isEqualToString:@"status"]) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        AVPlayerItemStatus status = AVPlayerItemStatusUnknown;
        NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
        if ([statusNumber isKindOfClass:[NSNumber class]]) {
            status = statusNumber.intValue;
        }
        [playerItem.audioSource onStatusChanged:status];
        switch (status) {
            case AVPlayerItemStatusReadyToPlay: {
                if (playerItem != _player.currentItem) return;
                // Detect buffering in different ways depending on whether we're playing
                if (_playing) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (_player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) {
                            [self enterBuffering:@"ready to play: playing, waitingToPlay"];
                        } else {
                            [self leaveBuffering:@"ready to play: playing, !waitingToPlay"];
                        }
                        [self updatePosition];
                    } else {
                        // If this happens when we're playing, check whether buffer is confirmed
                        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
                            // Stay in bufering - XXX Test
                            [self enterBuffering:@"ready to play: playing, bufferUnconfirmed && !playbackBufferFull"];
                        } else {
                            if (_player.currentItem.playbackBufferEmpty) {
                                // !_player.currentItem.playbackLikelyToKeepUp;
                                [self enterBuffering:@"ready to play: playing, playbackBufferEmpty"];
                            } else {
                                [self leaveBuffering:@"ready to play: playing, !playbackBufferEmpty"];
                            }
                            [self updatePosition];
                        }
                    }
                } else {
                    if (_player.currentItem.playbackBufferEmpty) {
                        [self enterBuffering:@"ready to play: !playing, playbackBufferEmpty"];
                        // || !_player.currentItem.playbackLikelyToKeepUp;
                    } else {
                        [self leaveBuffering:@"ready to play: !playing, !playbackBufferEmpty"];
                    }
                    [self updatePosition];
                }
                [self broadcastPlaybackEvent];
                if (_loadResult) {
                    _loadResult(@{@"duration": @([self getDurationMicroseconds])});
                    _loadResult = nil;
                }
                break;
            }
            case AVPlayerItemStatusFailed: {
                //NSLog(@"AVPlayerItemStatusFailed on item [%d]", [self indexForItem:playerItem]);
                if (playerItem == _player.currentItem) {
                    [self sendErrorForItem:playerItem];
                }
                break;
            }
            case AVPlayerItemStatusUnknown:
                break;
        }
    } else if ([keyPath isEqualToString:@"playbackBufferEmpty"] || [keyPath isEqualToString:@"playbackBufferFull"]) {
        // Use these values to detect buffering.
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        // If there's a seek in progress, these values are unreliable
        if (CMTIME_IS_VALID(_seekPos)) return;
        // Detect buffering in different ways depending on whether we're playing
        if (_playing) {
            if (@available(macOS 10.12, iOS 10.0, *)) {
                // We handle this with timeControlStatus instead.
            } else {
                if (_bufferUnconfirmed && playerItem.playbackBufferFull) {
                    _bufferUnconfirmed = NO;
                    [self leaveBuffering:@"playing, _bufferUnconfirmed && playbackBufferFull"];
                    [self updatePosition];
                    //NSLog(@"Buffering confirmed! leaving buffering");
                    [self broadcastPlaybackEvent];
                }
            }
        } else {
            if (playerItem.playbackBufferEmpty) {
                [self enterBuffering:@"!playing, playbackBufferEmpty"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            } else if (!playerItem.playbackBufferEmpty || playerItem.playbackBufferFull) {
                [self leaveBuffering:@"!playing, !playbackBufferEmpty || playbackBufferFull"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
            }
        }
    /* } else if ([keyPath isEqualToString:@"playbackLikelyToKeepUp"]) { */
    } else if ([keyPath isEqualToString:@"timeControlStatus"]) {
        if (@available(macOS 10.12, iOS 10.0, *)) {
            AVPlayerTimeControlStatus status = AVPlayerTimeControlStatusPaused;
            NSNumber *statusNumber = change[NSKeyValueChangeNewKey];
            if ([statusNumber isKindOfClass:[NSNumber class]]) {
                status = statusNumber.intValue;
            }
            switch (status) {
                case AVPlayerTimeControlStatusPaused:
                    //NSLog(@"AVPlayerTimeControlStatusPaused");
                    break;
                case AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate:
                    //NSLog(@"AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate");
                    if (_processingState != psCompleted) {
                        [self enterBuffering:@"timeControlStatus"];
                        [self updatePosition];
                        [self broadcastPlaybackEvent];
                    } else {
                        //NSLog(@"Ignoring wait signal because we reached the end");
                    }
                    break;
                case AVPlayerTimeControlStatusPlaying:
                    [self leaveBuffering:@"timeControlStatus"];
                    [self updatePosition];
                    [self broadcastPlaybackEvent];
                    break;
            }
        }
    } else if ([keyPath isEqualToString:@"externalPlaybackActive"]) {
        [self bstreamApplyVolume];
        [self bstreamCancelScheduledSkip];
        [self bstreamPublishStatus];
        [self bstreamProcessingTick];
    } else if ([keyPath isEqualToString:@"currentItem"] && !_player.currentItem) {
        [self bstreamApplyVolume];
        [self bstreamCancelScheduledSkip];
        _bstreamSkipFailures = 0;
        _bstreamSkipRetryAfter = 0;
        [self bstreamPublishStatus];
    } else if ([keyPath isEqualToString:@"currentItem"] && _player.currentItem) {
        id changedItem = change[NSKeyValueChangeNewKey];
        if (![changedItem isKindOfClass:[IndexedPlayerItem class]] || changedItem != _player.currentItem) return;
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)changedItem;
        int expectedIndex = [self indexForItem:playerItem];
        // A delayed observation may refer to an item from the previous load.
        // It cannot establish an index in the newly decoded source sequence.
        if (expectedIndex < 0 || (NSUInteger)expectedIndex >= _indexedAudioSources.count) return;
        _bstreamSkipFailures = 0;
        _bstreamSkipRetryAfter = 0;
        [self bstreamCancelScheduledSkip];
        [self bstreamAttachProcessingToItem:_player.currentItem];
        for (AVPlayerItem *oldItem in _bstreamAnalyzers.keyEnumerator.allObjects) {
            if (![_player.items containsObject:oldItem]) {
                [[_bstreamAnalyzers objectForKey:oldItem] invalidate];
                [_bstreamAnalyzers removeObjectForKey:oldItem];
            }
        }
        [self bstreamPublishStatus];
        //NSLog(@"currentItem -> [%d]", [self indexForItem:_player.currentItem]);
        BOOL publishItemChange = NO;
        //IndexedPlayerItem *oldPlayerItem = (IndexedPlayerItem *)change[NSKeyValueChangeOldKey];
        if (playerItem.status == AVPlayerItemStatusFailed) {
            [self sendErrorForItem:playerItem];
            return;
        } else {
            if (_index != expectedIndex) {
                // AVQueuePlayer will sometimes skip over error items without
                // notifying this observer.
                //NSLog(@"Queue change detected. Adjusting index from %d -> %d", _index, expectedIndex);
                _index = expectedIndex;
                [self updateEndAction];
                publishItemChange = YES;
            }
        }
        //NSLog(@"currentItem changed. _index=%d", _index);
        _bufferUnconfirmed = YES;
        // If we've skipped or transitioned to a new item and we're not
        // currently in the middle of a seek
        /* if (CMTIME_IS_INVALID(_seekPos) && playerItem.status == AVPlayerItemStatusReadyToPlay) { */
        /*     [self updatePosition]; */
        /*     IndexedAudioSource *source = playerItem.audioSource; */
        /*     // We should already be at position zero but for */
        /*     // ClippingAudioSource it might be off by some milliseconds so we */
        /*     // consider anything <= 100 as close enough. */
        /*     if ((int)(1000 * CMTimeGetSeconds(source.position)) > 100) { */
        /*         NSLog(@"On currentItem change, seeking back to zero"); */
        /*         BOOL shouldResumePlayback = NO; */
        /*         AVPlayerActionAtItemEnd originalEndAction = _player.actionAtItemEnd; */
        /*         if (_playing && CMTimeGetSeconds(CMTimeSubtract(source.position, source.duration)) >= 0) { */
        /*             NSLog(@"Need to pause while rewinding because we're at the end"); */
        /*             shouldResumePlayback = YES; */
        /*             _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; */
        /*             [_player pause]; */
        /*         } */
        /*         [self enterBuffering:@"currentItem changed, seeking"]; */
        /*         [self updatePosition]; */
        /*         [self broadcastPlaybackEvent]; */
        /*         __weak __typeof__(self) weakSelf = self; */
        /*         [source seek:kCMTimeZero completionHandler:^(BOOL finished) { */
        /*             [weakSelf leaveBuffering:@"currentItem changed, finished seek"]; */
        /*             [weakSelf updatePosition]; */
        /*             [weakSelf broadcastPlaybackEvent]; */
        /*             if (shouldResumePlayback) { */
        /*                 weakSelf.player.actionAtItemEnd = originalEndAction; */
        /*                 // TODO: This logic is almost duplicated in seek. See if we can reuse this code. */
        /*                 weakSelf.player.rate = weakSelf.speed; */
        /*             } */
        /*         }]; */
        /*     } else { */
        /*         // Already at zero, no need to seek. */
        /*     } */
        /* } */

        if (_justAdvanced) {
            publishItemChange = YES;
            IndexedAudioSource *audioSource = playerItem.audioSource;
            if (_loopMode == lmLoopOne) {
                [audioSource flip];
                [self enqueueFrom:_index];
            } else if (_loopMode == lmLoopAll) {
                if (_index == [_order[0] intValue] && playerItem == audioSource.playerItem2) {
                    [audioSource flip];
                    [self enqueueFrom:_index];
                } else if (!_enqueuedAll) {
                    [self enqueueFrom:_index];
                } else {
                    [self updateEndAction];
                }
            } else if (!_enqueuedAll) {
                [self enqueueFrom:_index];
            }
            _justAdvanced = NO;
        }
        [self bstreamApplyVolume];
        [self bstreamApplyPlaybackRate];
        // Pair the successor's index/duration with its own clock, after any
        // loop-item flip. Initial attachment keeps its existing load events.
        if (publishItemChange) {
            [self updatePosition];
            [self broadcastPlaybackEvent];
        }
    } else if ([keyPath isEqualToString:@"loadedTimeRanges"]) {
        [self bstreamProcessingTick];
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)object;
        if (playerItem != _player.currentItem) return;
        int pos = [self getBufferedPosition];
        if (pos != _bufferedPosition) {
            _bufferedPosition = pos;
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)sendErrorForItem:(IndexedPlayerItem *)playerItem {
    [self sendError:@((int)playerItem.error.code) errorMessage:playerItem.error.localizedDescription playerItem:playerItem switchToIdle:YES];
    [_player removeAllItems];
}

- (void)sendError:(NSNumber *)errorCode errorMessage:(NSString *)errorMessage playerItem:(IndexedPlayerItem *)playerItem switchToIdle:(BOOL)switchToIdle {
    //NSLog(@"sendError (%@) %@", errorCode, errorMessage);
    FlutterError *flutterError = [FlutterError errorWithCode:[NSString stringWithFormat:@"%@", errorCode]
                                                     message:errorMessage
                                                     details:playerItem != nil ? @{@"index": @([self indexForItem:playerItem])} : nil];
    [_eventChannel sendEvent:flutterError];
    _errorCode = errorCode;
    _errorMessage = errorMessage;
    if (switchToIdle) {
        _processingState = psIdle;
    }
    [self broadcastPlaybackEvent];
    if (_loadResult && playerItem == _player.currentItem) {
        _loadResult(flutterError);
        _loadResult = nil;
    }
}

- (void)abortExistingConnection:(BOOL)switchToIdle {
    [self sendError:@(ERROR_ABORT) errorMessage:@"Connection aborted" playerItem:nil switchToIdle:switchToIdle];
}

- (int)indexForItem:(IndexedPlayerItem *)playerItem {
    for (int i = 0; i < _indexedAudioSources.count; i++) {
        if (_indexedAudioSources[i].playerItem == playerItem || _indexedAudioSources[i].playerItem2 == playerItem) {
            return i;
        }
    }
    return -1;
}

- (void)play {
    [self play:nil];
}

- (void)play:(FlutterResult)result {
    if (_playing) {
        if (result) {
            result(@{});
        }
        return;
    }
    if (result) {
        if (_playResult) {
            //NSLog(@"INTERRUPTING PLAY");
            _playResult(@{});
        }
        _playResult = result;
    }
    _playing = YES;
    [self bstreamApplyPlaybackRate];
    [self bstreamProcessingTick];
    [self updatePosition];
    if (@available(macOS 10.12, iOS 10.0, *)) {}
    else {
        if (_bufferUnconfirmed && !_player.currentItem.playbackBufferFull) {
            [self enterBuffering:@"play, _bufferUnconfirmed && !playbackBufferFull"];
            [self broadcastPlaybackEvent];
        }
    }
}

- (void)pause {
    if (!_playing) return;
    BOOL wasWaitingForTap = _bstreamWaitingForTap && _processingState == psBuffering;
    [self bstreamCancelScheduledSkip];
    _playing = NO;
    _bstreamWaitingForTap = NO;
    [_player pause];
    if (wasWaitingForTap && _player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
        [self leaveBuffering:@"paused during audio processing installation"];
    }
    [self updatePosition];
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO PAUSE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)complete {
    _bstreamWaitingForTap = NO;
    [self updatePosition];
    _processingState = psCompleted;
    [self broadcastPlaybackEvent];
    if (_playResult) {
        //NSLog(@"PLAY FINISHED DUE TO COMPLETE");
        _playResult(@{});
        _playResult = nil;
    }
}

- (void)setVolume:(float)volume {
    _volume = volume;
    [self bstreamApplyVolume];
}

- (void)setSpeed:(float)speed {
    // NOTE: We ideally should check _player.currentItem.canPlaySlowForward and
    // canPlayFastForward, but these properties are unreliable and the official
    // documentation is unclear and contradictory.
    //
    // Source #1:
    // https://developer.apple.com/documentation/avfoundation/avplayer/1388846-rate?language=objc
    //
    //     Rates other than 0.0 and 1.0 can be used if the associated player
    //     item returns YES for the AVPlayerItem properties canPlaySlowForward
    //     or canPlayFastForward.
    //
    // Source #2:
    // https://developer.apple.com/library/archive/qa/qa1772/_index.html
    //
    //     An AVPlayerItem whose status property equals
    //     AVPlayerItemStatusReadyToPlay can be played at rates between 1.0 and
    //     2.0, inclusive, even if AVPlayerItem.canPlayFastForward is NO.
    //     AVPlayerItem.canPlayFastForward indicates whether the item can be
    //     played at rates greater than 2.0.
    //
    // But in practice, it appears that even if AVPlayerItem.canPlayFastForward
    // is NO, rates greater than 2.0 still work sometimes.
    //
    // So for now, we just let the app pass in any speed and hope for the best.
    // There is no way to reliably query whether the requested speed is
    // supported.
    _speed = speed;
    if (_playing && _player) {
        [self bstreamApplyPlaybackRate];
    }
    [self updatePosition];
}

- (void)setLoopMode:(int)loopMode {
    if (loopMode == _loopMode) return;
    _loopMode = loopMode;
    [self enqueueFrom:_index];
}

- (void)updateEndAction {
    // Should be called in the following situations:
    // - when the audio source changes
    // - when _index changes
    // - when the loop mode changes.
    // - when the shuffle order changes. (TODO)
    // - when the shuffle mode changes.
    if (!_player) return;
    if (!_audioSource || _index < 0 || (NSUInteger)_index >= _indexedAudioSources.count ||
            (NSUInteger)_index >= _orderInv.count) {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        return;
    }
    NSNumber *orderPosition = _orderInv[_index];
    if (![orderPosition isKindOfClass:[NSNumber class]] || orderPosition.integerValue < 0 ||
            (NSUInteger)orderPosition.integerValue >= _order.count) {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        return;
    }
    if (_loopMode != lmLoopOff || orderPosition.integerValue + 1 < (NSInteger)_order.count) {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    } else {
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause; // AVPlayerActionAtItemEndNone
    }
}

- (void)setShuffleModeEnabled:(BOOL)shuffleModeEnabled {
    //NSLog(@"setShuffleModeEnabled: %d", shuffleModeEnabled);
    _shuffleModeEnabled = shuffleModeEnabled;
    if (!_audioSource) return;

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)setShuffleOrder:(NSDictionary *)dict {
    if (!_audioSource) return;

    [_audioSource decodeShuffleOrder:dict];

    [self updateOrder];

    [self enqueueFrom:_index];
}

- (void)dumpQueue {
    for (int i = 0; i < _player.items.count; i++) {
        IndexedPlayerItem *playerItem = (IndexedPlayerItem *)_player.items[i];
        int j = [self indexForItem:playerItem];
        NSLog(@"- %d", j);
    }
}

- (void)setAutomaticallyWaitsToMinimizeStalling:(bool)automaticallyWaitsToMinimizeStalling {
    _automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
    if (@available(macOS 10.12, iOS 10.0, *)) {
        if(_player) {
            _player.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling;
        }
    }
}

- (void)setCanUseNetworkResourcesForLiveStreamingWhilePaused:(BOOL)enabled {
    _loadControl.canUseNetworkResourcesForLiveStreamingWhilePaused = enabled;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyCanUseNetworkResourcesForLiveStreamingWhilePaused];
    }
}

- (void)setPreferredPeakBitRate:(NSNumber *)preferredPeakBitRate {
    _loadControl.preferredPeakBitRate = preferredPeakBitRate;
    if (!_indexedAudioSources) return;
    for (int i = 0; i < [_indexedAudioSources count]; i++) {
        [_indexedAudioSources[i] applyPreferredPeakBitRate];
    }
}

- (void)setAllowsExternalPlayback:(BOOL)allowsExternalPlayback {
    _allowsExternalPlayback = allowsExternalPlayback;
    if (@available(macOS 10.11, iOS 6.0, *)) {
        if (_player) {
            _player.allowsExternalPlayback = allowsExternalPlayback;
        }
    }
}

- (void)seek:(CMTime)position index:(NSNumber *)newIndex completionHandler:(void (^)(BOOL))completionHandler {
    _bstreamSkipFailures = 0;
    _bstreamSkipRetryAfter = 0;
    [self bstreamPublishStatus];
    [self bstreamCancelScheduledSkip];
    [[_bstreamProcessors objectForKey:_player.currentItem] resetAfterSeekToTime:kCMTimeInvalid fadeIn:NO];
    if (_processingState == psIdle || _processingState == psLoading) {
        if (completionHandler) {
            completionHandler(NO);
        }
        return;
    }
    int index = _index;
    if (newIndex != (id)[NSNull null]) {
        index = [newIndex intValue];
    }
    if (index != _index) {
        // Jump to a new item
        /* if (_playing && index == _index + 1) { */
        /*     // Special case for jumping to the very next item */
        /*     NSLog(@"seek to next item: %d -> %d", _index, index); */
        /*     [_indexedAudioSources[_index] seek:kCMTimeZero]; */
        /*     _index = index; */
        /*     [_player advanceToNextItem]; */
        /*     [self broadcastPlaybackEvent]; */
        /* } else */
        {
            // Jump to a distant item
            //NSLog(@"seek# jump to distant item: %d -> %d", _index, index);
            if (_playing) {
                [_player pause];
            }
            [_indexedAudioSources[_index] seek:kCMTimeZero];
            // The "currentItem" key observer will respect that a seek is already in progress
            _seekPos = position;
            [self updatePosition];
            [self enqueueFrom:index];
            IndexedAudioSource *source = _indexedAudioSources[_index];
            if (abs((int)(1000 * CMTimeGetSeconds(CMTimeSubtract(source.position, position)))) > 100) {
                [self enterBuffering:@"seek to index"];
                [self updatePosition];
                [self broadcastPlaybackEvent];
                [source seek:position completionHandler:^(BOOL finished) {
                    if (@available(macOS 10.12, iOS 10.0, *)) {
                        if (self->_playing) {
                            // Handled by timeControlStatus
                        } else {
                            if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                                // Stay in buffering
                            } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                                [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                                [self updatePosition];
                                [self broadcastPlaybackEvent];
                            }
                        }
                    } else {
                        if (self->_bufferUnconfirmed && !self->_player.currentItem.playbackBufferFull) {
                            // Stay in buffering
                        } else if (source.playerItem.status == AVPlayerItemStatusReadyToPlay) {
                            [self leaveBuffering:@"seek to index finished, (!bufferUnconfirmed || playbackBufferFull) && ready to play"];
                            [self updatePosition];
                            [self broadcastPlaybackEvent];
                        }
                    }
                    if (self->_playing) {
                        [self bstreamApplyPlaybackRate];
                    }
                    self->_seekPos = kCMTimeInvalid;
                    [self broadcastPlaybackEvent];
                    if (completionHandler) {
                        completionHandler(finished);
                    }
                }];
            } else {
                _seekPos = kCMTimeInvalid;
                if (_playing) {
                    if (@available(iOS 10.0, *)) {
                        // NOTE: Re-enable this line only after figuring out
                        // how to detect buffering when buffered audio is not
                        // immediately available.
                        //[_player playImmediatelyAtRate:_speed];
                        [self bstreamApplyPlaybackRate];
                    } else {
                        [self bstreamApplyPlaybackRate];
                    }
                }
                [self broadcastPlaybackEvent];
                completionHandler(YES);
            }
        }
    } else {
        // Seek within an item
        if (_playing) {
            [_player pause];
        }
        _seekPos = position;
        //NSLog(@"seek. enter buffering. pos = %d", (int)(1000*CMTimeGetSeconds(_indexedAudioSources[_index].position)));
        // TODO: Move this into a separate method so it can also
        // be used in skip.
        [self enterBuffering:@"seek"];
        [self updatePosition];
        [self broadcastPlaybackEvent];
        [_indexedAudioSources[_index] seek:position completionHandler:^(BOOL finished) {
            [self updatePosition];
            if (self->_playing) {
                // If playing, buffering will be detected either by:
                // 1. checkForDiscontinuity
                // 2. timeControlStatus
                if (@available(iOS 10.0, *)) {
                    // NOTE: Re-enable this line only after figuring out how to
                    // detect buffering when buffered audio is not immediately
                    // available.
                    //[_player playImmediatelyAtRate:_speed];
                    [self bstreamApplyPlaybackRate];
                } else {
                    [self bstreamApplyPlaybackRate];
                }
            } else {
                // If not playing, there is no reliable way to detect
                // when buffering has completed, so we use
                // !playbackBufferEmpty. Although this always seems to
                // be full even right after a seek.
                if (self->_player.currentItem.playbackBufferEmpty) {
                    [self enterBuffering:@"seek finished, playbackBufferEmpty"];
                } else {
                    [self leaveBuffering:@"seek finished, !playbackBufferEmpty"];
                }
                [self updatePosition];
                if (self->_processingState != psBuffering) {
                    [self broadcastPlaybackEvent];
                }
            }
            self->_seekPos = kCMTimeInvalid;
            [self broadcastPlaybackEvent];
            if (completionHandler) {
                completionHandler(finished);
            }
        }];
    }
}

- (void)dispose:(BOOL)calledFromDealloc {
    _bstreamDisposed = YES;
    // Stop audibility before removing the mix that owns output attenuation.
    [_player pause];
    [self bstreamCancelScheduledSkip];
    if (_bstreamTimeObserver) {
        [_player removeTimeObserver:_bstreamTimeObserver];
        _bstreamTimeObserver = nil;
    }
    for (BStreamAudioProcessingTap *processor in _bstreamProcessors.objectEnumerator) [processor invalidate];
    for (BStreamSilenceAnalyzer *analyzer in _bstreamAnalyzers.objectEnumerator) [analyzer invalidate];
    [_bstreamProcessors removeAllObjects];
    [_bstreamAnalyzers removeAllObjects];
    if (!_player) return;
    if (_processingState != psIdle) {
        [self updatePosition];
        if (!calledFromDealloc) {
            [self broadcastPlaybackEvent];
        }
        if (_playResult) {
            //NSLog(@"PLAY FINISHED DUE TO STOP");
            _playResult(@{});
            _playResult = nil;
        }

        _processingState = psIdle;
        // If used just before destroying the current FlutterEngine, this will result in:
        // NSInternalInconsistencyException: 'Sending a message before the FlutterEngine has been run.'
        //[self broadcastPlaybackEvent];
    }
    if (_timeObserver) {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = 0;
    }
    if (_indexedAudioSources) {
        for (int i = 0; i < [_indexedAudioSources count]; i++) {
            [self removeItemObservers:_indexedAudioSources[i].playerItem];
            if (_indexedAudioSources[i].playerItem2) {
                [self removeItemObservers:_indexedAudioSources[i].playerItem2];
            }
        }
        _indexedAudioSources = nil;
    }
    _audioSource = nil;
    if (_player) {
        [_player removeObserver:self forKeyPath:@"currentItem"];
        [_player removeObserver:self forKeyPath:@"externalPlaybackActive"];
        if (@available(macOS 10.12, iOS 10.0, *)) {
            [_player removeObserver:self forKeyPath:@"timeControlStatus"];
        }
        _player = nil;
    }
    // Untested:
    [_eventChannel dispose];
    [_dataEventChannel dispose];
    [_methodChannel setMethodCallHandler:nil];
}

@end
