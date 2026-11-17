#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A bounded, optional analysis pass. It never changes the item's playback.
/// Times/ranges use the AVAsset's original timeline, including clipped items.
@interface BStreamSilenceAnalyzer : NSObject

- (instancetype)initWithItem:(AVPlayerItem *)item;
/// A supplied identifier must include the source and its authorization context.
/// Without one, local files share by versioned URL; remote assets share only
/// when they are the same AVAsset instance, never just by an unauthenticated URL.
- (instancetype)initWithItem:(AVPlayerItem *)item
            cacheIdentifier:(nullable NSString *)cacheIdentifier;

@property(nonatomic, copy, nullable) void (^onStatusChange)(void);
@property(nonatomic, readonly) BOOL supported;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly, nullable) NSString *error;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *diagnostics;

/// Coalesces requests and scans no more than 12 seconds ahead. Remote media is
/// constrained further to the caller's contiguous buffered range.
- (void)requestAnalysisAtTime:(CMTime)position bufferedUntil:(CMTime)end;
- (CMTime)gapEndForTime:(CMTime)time;
/// Earliest confirmed removal interval whose end is after time, or nil.
- (nullable NSValue *)nextGapAfterTime:(CMTime)time;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
