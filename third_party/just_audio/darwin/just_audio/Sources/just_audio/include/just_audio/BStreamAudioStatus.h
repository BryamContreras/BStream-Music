#ifndef BSTREAM_AUDIO_STATUS_H
#define BSTREAM_AUDIO_STATUS_H

#import <Foundation/Foundation.h>

// C logical expressions have type int. Boxing them directly with @() sends
// a number through Flutter's codec, even when its value is 0 or 1. Always use
// the Foundation boolean singletons for status fields decoded as Dart bool.
NS_INLINE NSNumber *BStreamAudioStatusBoolean(BOOL value) {
    return value ? @YES : @NO;
}

#endif
