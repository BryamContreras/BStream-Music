import Flutter
import AVFoundation
import AudioToolbox
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testLocalQualitySourcePolicyRejectsNetworkAndRemoteFileAuthorities() {
    XCTAssertNotNil(IOSLocalAudioQualityReader.localURL("/tmp/song name.wav"))
    XCTAssertNotNil(IOSLocalAudioQualityReader.localURL("file:///tmp/song%20name.m4a"))
    XCTAssertNotNil(IOSLocalAudioQualityReader.localURL("ipod-library://item/item.m4a?id=12"))
    for source in ["", "song.mp3", "https://example.com/song.mp3", "http://127.0.0.1/song",
                   "file://remote-host/song.mp3", "content://media/audio/1", "data:audio/aac;base64,AA"] {
      XCTAssertNil(IOSLocalAudioQualityReader.localURL(source), source)
    }
  }

  func testLocalQualityNamesEncodedCodecsWithoutAssumingDecodedPCM() {
    XCTAssertEqual(IOSLocalAudioQualityReader.formatName(kAudioFormatMPEG4AAC)?.codec, "AAC")
    XCTAssertEqual(IOSLocalAudioQualityReader.formatName(kAudioFormatMPEGLayer3)?.codec, "MP3")
    XCTAssertEqual(IOSLocalAudioQualityReader.formatName(kAudioFormatOpus)?.codec, "Opus")
    XCTAssertEqual(IOSLocalAudioQualityReader.formatName(kAudioFormatFLAC)?.codec, "FLAC")
    XCTAssertEqual(IOSLocalAudioQualityReader.formatName(kAudioFormatAppleLossless)?.codec, "ALAC")
    XCTAssertNil(IOSLocalAudioQualityReader.formatName(0))
  }

  func testLocalQualityDoesNotGuessWhichAlternateAudioTrackIsPlaying() {
    XCTAssertTrue(IOSLocalAudioQualityReader.canDescribeAudioTrack(1))
    XCTAssertFalse(IOSLocalAudioQualityReader.canDescribeAudioTrack(0))
    XCTAssertFalse(IOSLocalAudioQualityReader.canDescribeAudioTrack(2))
    XCTAssertFalse(IOSLocalAudioQualityReader.canDescribeAudioTrack(3))
  }

  func testLocalQualityUsesOriginalStereoPCMFormatAndItsFixedByteRate() throws {
    var basic = AudioStreamBasicDescription(
      mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
      mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
    )
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &basic, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil,
      formatDescriptionOut: &description
    )
    XCTAssertEqual(status, noErr)
    let payload = IOSLocalAudioQualityReader.payload(
      descriptions: [try XCTUnwrap(description)], bitrate: 0
    )
    XCTAssertEqual(payload?["codec"] as? String, "PCM")
    XCTAssertEqual(payload?["sampleRate"] as? Int, 44100)
    XCTAssertEqual(payload?["channels"] as? Int, 2)
    XCTAssertEqual(payload?["bitrate"] as? Int, 1411200)
  }

}
