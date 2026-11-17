#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One AVPlayerItem's in-place DSP. The mix is installed once, before audibility;
/// subsequent presets only change atomic parameters, never the active mix.
@interface BStreamAudioProcessingTap : NSObject
@property(nonatomic, copy, nullable) void (^onStatusChange)(void);
@property(nonatomic, readonly) BOOL supported;
@property(nonatomic, readonly) BOOL configured;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly, nullable) NSString *error;
- (instancetype)initWithItem:(AVPlayerItem *)item;
- (void)configureEnabled:(BOOL)enabled gains:(NSArray<NSNumber *> *)gains revision:(uint64_t)revision;
- (NSDictionary *)diagnostics;
- (BOOL)consumeStatusChange;
- (void)validatePlaybackAtTime:(CMTime)time;
- (void)fadeOutAtTime:(CMTime)time;
- (void)resetAfterSeekToTime:(CMTime)time fadeIn:(BOOL)fadeIn;
- (void)cancelFade;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
