#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "BStreamSilenceAnalyzer.h"
#import "BStreamAudioProcessingTap.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); \
} } while (0)

static const double Rate = 48000;

static CMTime Time(double seconds) { return CMTimeMakeWithSeconds(seconds, 1000000); }
static double Seconds(CMTime value) { return CMTimeGetSeconds(value); }

static BOOL WaitUntil(BOOL (^condition)(void), double timeout) {
    double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    do {
        @autoreleasepool {
            if (condition()) return YES;
            // AVFoundation metadata completions and helper notifications need
            // the main run loop. Never block it on a semaphore or sleep.
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return condition();
}

static void Pump(double duration) {
    double end = NSProcessInfo.processInfo.systemUptime + duration;
    (void)WaitUntil(^BOOL { return NSProcessInfo.processInfo.systemUptime >= end; }, duration + 0.1);
}

static uint64_t Counter(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    CHECK([value isKindOfClass:[NSNumber class]]);
    return [value unsignedLongLongValue];
}

static void Store16(uint8_t *bytes, uint16_t value) {
    bytes[0] = (uint8_t)value;
    bytes[1] = (uint8_t)(value >> 8);
}

static void Store32(uint8_t *bytes, uint32_t value) {
    for (int i = 0; i < 4; ++i) bytes[i] = (uint8_t)(value >> (8 * i));
}

static NSURL *WriteFixture(NSURL *directory) {
    const uint32_t frames = (uint32_t)(27 * Rate);
    NSMutableData *data = [NSMutableData dataWithLength:44 + frames * 2];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "RIFF", 4);
    Store32(bytes + 4, (uint32_t)data.length - 8);
    memcpy(bytes + 8, "WAVEfmt ", 8);
    Store32(bytes + 16, 16);
    Store16(bytes + 20, 1);
    Store16(bytes + 22, 1);
    Store32(bytes + 24, (uint32_t)Rate);
    Store32(bytes + 28, (uint32_t)Rate * 2);
    Store16(bytes + 32, 2);
    Store16(bytes + 34, 16);
    memcpy(bytes + 36, "data", 4);
    Store32(bytes + 40, frames * 2);
    for (uint32_t frame = 0; frame < frames; ++frame) {
        double time = frame / Rate;
        double peak = time < 0.5 || (time >= 4.5 && time < 5) ||
            (time >= 14 && time < 14.5) || (time >= 20.5 && time < 21) ? 2800 :
            (time >= 14.5 && time < 20.5 ? 80 : 0);
        int16_t sample = (int16_t)lrint(peak * sin(2 * 3.14159265358979323846 * 440 * time));
        Store16(bytes + 44 + frame * 2, (uint16_t)sample);
    }
    NSURL *url = [directory URLByAppendingPathComponent:@"music-safe.wav"];
    NSError *error = nil;
    CHECK([data writeToURL:url options:NSDataWritingAtomic error:&error]);
    return url;
}

static AVPlayerItem *Item(NSURL *url) {
    return [AVPlayerItem playerItemWithAsset:[AVURLAsset URLAssetWithURL:url options:nil]];
}

static void AwaitAnalysis(BStreamSilenceAnalyzer *analyzer, uint64_t milliseconds) {
    BOOL completed = WaitUntil(^BOOL {
        NSDictionary *status = analyzer.diagnostics;
        return !analyzer.supported ||
            (Counter(status, @"analyzedUntilMs") >= milliseconds && ![status[@"analyzing"] boolValue]);
    }, 15);
    if (!completed || !analyzer.supported) NSLog(@"Analysis diagnostics: %@", analyzer.diagnostics);
    CHECK(completed);
    CHECK(analyzer.supported);
    CHECK(analyzer.ready);
    CHECK(analyzer.error == nil);
}

static void TestBoundedSharedAnalysis(NSURL *url) {
    AVPlayerItem *firstItem = Item(url);
    firstItem.preferredForwardBufferDuration = 2;
    BStreamSilenceAnalyzer *first = [[BStreamSilenceAnalyzer alloc] initWithItem:firstItem];
    __block BOOL callbacksOnMain = YES;
    __block NSUInteger callbacks = 0;
    first.onStatusChange = ^{
        callbacksOnMain = callbacksOnMain && NSThread.isMainThread;
        ++callbacks;
    };
    CHECK(fabs(firstItem.preferredForwardBufferDuration - 12) < 0.001);
    [first requestAnalysisAtTime:Time(0) bufferedUntil:kCMTimeInvalid];
    AwaitAnalysis(first, 11990);
    CHECK(Counter(first.diagnostics, @"analyzedUntilMs") <= 12001);
    CHECK(Counter(first.diagnostics, @"decodedFrames") <= (uint64_t)(12 * Rate + 1));
    CHECK(CMTIME_IS_INVALID([first gapEndForTime:Time(2)])); // four-second musical pause
    CHECK(CMTIME_IS_INVALID([first gapEndForTime:Time(5)])); // leading margin stays audible
    NSValue *initial = [first nextGapAfterTime:kCMTimeZero];
    CHECK(initial != nil);
    CHECK(fabs(Seconds(initial.CMTimeRangeValue.start) - 5.15) < 0.06);
    CHECK(fabs(Seconds(CMTimeRangeGetEnd(initial.CMTimeRangeValue)) - 11.75) < 0.06);
    CHECK(fabs(Seconds([first gapEndForTime:Time(7)]) - 11.75) < 0.06);
    Pump(0.05);
    CHECK(callbacks > 0 && callbacksOnMain);

    uint64_t initialReaders = Counter(first.diagnostics, @"readersCreated");
    uint64_t initialFrames = Counter(first.diagnostics, @"decodedFrames");
    CHECK(initialReaders == 1);
    for (int i = 0; i < 20; ++i) [first requestAnalysisAtTime:Time(0) bufferedUntil:kCMTimeInvalid];
    Pump(0.10);
    CHECK(Counter(first.diagnostics, @"readersCreated") == initialReaders);
    CHECK(Counter(first.diagnostics, @"decodedFrames") == initialFrames);

    // Different AVURLAsset objects for the same versioned local file share
    // actual decoded coverage, rather than doing the same work on each deck.
    AVPlayerItem *secondItem = Item(url);
    secondItem.preferredForwardBufferDuration = 3;
    BStreamSilenceAnalyzer *second = [[BStreamSilenceAnalyzer alloc] initWithItem:secondItem];
    CHECK(second.ready);
    CHECK(Counter(second.diagnostics, @"sharedUsers") == 2);
    [second requestAnalysisAtTime:Time(0) bufferedUntil:kCMTimeInvalid];
    Pump(0.10);
    CHECK(Counter(second.diagnostics, @"decodedFrames") == initialFrames);
    CHECK(Counter(second.diagnostics, @"readersCreated") == initialReaders);

    // Removing one subscriber must not cancel the other subscriber's pending
    // request. This is deterministic even if the short native decode finishes
    // before the main thread gets another run-loop turn.
    [second requestAnalysisAtTime:Time(12) bufferedUntil:kCMTimeInvalid];
    [first invalidate];
    CHECK(!first.supported);
    CHECK(fabs(firstItem.preferredForwardBufferDuration - 2) < 0.001);
    CHECK(fabs(secondItem.preferredForwardBufferDuration - 12) < 0.001);
    AwaitAnalysis(second, 23990);
    CHECK(Counter(second.diagnostics, @"sharedUsers") == 1);
    CHECK(Counter(second.diagnostics, @"readersCreated") == initialReaders + 1);
    CHECK(fabs(Seconds([second gapEndForTime:Time(12)]) - 13.75) < 0.06);
    CHECK(CMTIME_IS_INVALID([second gapEndForTime:Time(13.95)])); // trailing margin
    CHECK(CMTIME_IS_INVALID([second gapEndForTime:Time(17)])); // very quiet music

    [second requestAnalysisAtTime:Time(15) bufferedUntil:kCMTimeInvalid];
    AwaitAnalysis(second, 26990);
    NSValue *outro = [second nextGapAfterTime:Time(17)];
    CHECK(outro != nil);
    CHECK(fabs(Seconds(outro.CMTimeRangeValue.start) - 21.15) < 0.06);
    CHECK(fabs(Seconds(CMTimeRangeGetEnd(outro.CMTimeRangeValue)) - 26.75) < 0.06);

    // Restore only our own buffering hint. A later setting from another
    // consumer must survive analyzer disposal.
    secondItem.preferredForwardBufferDuration = 20;
    [second invalidate];
    CHECK(fabs(secondItem.preferredForwardBufferDuration - 20) < 0.001);
    puts("Darwin bounded/shared AVAssetReader analysis passed");
}

static void TestTapLifecycleAndWatchdog(NSURL *url) {
    AVPlayerItem *item = Item(url);
    __weak BStreamAudioProcessingTap *retired = nil;
    @autoreleasepool {
        BStreamAudioProcessingTap *tap = [[BStreamAudioProcessingTap alloc] initWithItem:item];
        CHECK(WaitUntil(^BOOL { return tap.ready; }, 10));
        CHECK(tap.supported && tap.error == nil);
        CHECK(item.audioMix != nil);
        CHECK(item.audioMix.inputParameters.count == 1);
        CHECK(item.audioMix.inputParameters.firstObject.audioTapProcessor != NULL);
        AVAudioMix *installed = item.audioMix;
        [tap configureEnabled:YES gains:@[@6, @3, @0, @0, @0] revision:1];
        [tap configureEnabled:YES gains:@[@0, @0, @(-3.5), @0, @0] revision:2];
        CHECK(item.audioMix == installed); // preset changes never replace the mix
        [tap fadeOutAtTime:Time(5)];
        [tap resetAfterSeekToTime:Time(9) fadeIn:YES];
        [tap cancelFade];
        [tap invalidate];
        CHECK(item.audioMix == nil);
        retired = tap;
        installed = nil;
        tap = nil;
    }
    CHECK(WaitUntil(^BOOL { return retired == nil; }, 5));

    @autoreleasepool {
        item.forwardPlaybackEndTime = Time(10);
        BStreamAudioProcessingTap *replacement = [[BStreamAudioProcessingTap alloc] initWithItem:item];
        CHECK(WaitUntil(^BOOL { return replacement.ready; }, 10));
        CHECK(replacement.supported && item.audioMix != nil);
        [replacement configureEnabled:YES gains:@[@3, @0, @0, @0, @0] revision:3];
        // No AVPlayer or output device is used by this executable. Supplying
        // advancing source-clock observations while zero PCM frames arrive
        // exercises the route watchdog without requiring physical audio.
        CHECK(Counter([replacement diagnostics], @"processedFrames") == 0);
        [replacement validatePlaybackAtTime:Time(0)];
        [replacement validatePlaybackAtTime:Time(2)];
        CHECK(!replacement.supported);
        CHECK(!replacement.configured);
        CHECK(replacement.error.length > 0);
        [replacement invalidate];
        CHECK(item.audioMix == nil);
    }

    @autoreleasepool {
        AVPlayerItem *foreignItem = Item(url);
        foreignItem.audioMix = [AVMutableAudioMix audioMix];
        AVAudioMix *foreign = foreignItem.audioMix;
        BStreamAudioProcessingTap *tap = [[BStreamAudioProcessingTap alloc] initWithItem:foreignItem];
        CHECK(WaitUntil(^BOOL { return tap.ready; }, 10));
        CHECK(!tap.supported);
        [tap invalidate];
        CHECK(foreignItem.audioMix == foreign);
        foreignItem.audioMix = nil;
    }
    puts("Darwin audio-tap lifecycle, reclip and route watchdog passed");
}

int main(void) {
    @autoreleasepool {
        CHECK(NSThread.isMainThread);
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[@"bstream-darwin-test-" stringByAppendingString:NSUUID.UUID.UUIDString]]
                                     isDirectory:YES];
        NSError *error = nil;
        CHECK([[NSFileManager defaultManager] createDirectoryAtURL:directory
                                      withIntermediateDirectories:NO attributes:nil error:&error]);
        NSURL *fixture = WriteFixture(directory);
        TestBoundedSharedAnalysis(fixture);
        TestTapLifecycleAndWatchdog(fixture);
        CHECK([[NSFileManager defaultManager] removeItemAtURL:directory error:&error]);
        puts("BStream Darwin AVFoundation processing: all tests passed");
    }
    return 0;
}
