# BStream mobile audio customizations

This directory vendors `just_audio` 0.10.6 under its original BSD-3-Clause
license. BStream preserves compatibility with the existing Dart API. Native
processing extensions are isolated in the Android and Darwin implementations.

## iOS PCM processing and silence skipping

`darwinAudioEffects` carries the same `bstreamAudioEqualizer` marker as Android.
The existing per-player method channel accepts the aggregate configure/read
methods and emits availability changes, including `skipSilenceSupported`.
Parameters, diagnostics and counters cross this channel; PCM never does.

`BStreamAudioProcessingTap` installs one mix per enqueued item and gates initial
audibility until installation completes or explicitly falls back. It changes
atomic parameter snapshots thereafter, preserving the item and media clock.
The render callback processes native packed PCM in place without allocating or
locking. Unsupported formats preserve the source audio and report unavailable;
a route that advances without ever delivering PCM cannot silently claim EQ.
Mix cleanup checks ownership so item reuse/clipping can install a fresh tap.

`BStreamAudioDSP.c` contains the independent ten-band biquads, internal
headroom, 25 ms transition and conservative RMS/peak silence classifier.
AVPlayer taps must preserve frame counts: silence is removed through bounded
`AVAssetReader` lookahead and exact AVPlayerItem seeks, not through tap sample
compaction. Analysis is optional, limited to 12 seconds ahead and to contiguous
buffered remote media; readers refill in batches. A bounded shared cache avoids
repeating confirmed analysis. The decoder classifies original, unequalized PCM.
The player's timeline, crossfade gains and playback intent remain authoritative.

HLS/live, protected, multitrack and unreadable assets are not claimed as
processable. Disabling analysis cancels the optional reader and restores its
buffer hint. Late work and seeks are guarded by item identity and generations;
failed seeks back off instead of looping. Core tests run without Apple APIs;
native wrappers and shared simulator scenarios require a Mac with Xcode.
See [iOS audio processing](../../docs/ios_audio_processing.md).

## Android processing and routing

The small `BStreamAudioOutput` native facade shares a media-output preference
across the active and standby/crossfade players using weak references. It calls
Media3's `setPreferredAudioDevice` on existing engines and reapplies the choice
when an engine is initialized. A disconnected/invalid device falls back to the
system default. This is a best-effort AudioTrack preference, not a promise from
the hardware; no communication mode, SCO or global Bluetooth setting is used.
The app's native output menu controls Android's media stream volume separately
from the player's per-track gain. The public output-routing API is unchanged.

The Android audio engine explicitly disables Media3 video-track selection.
A resolver may return a muxed container, but only its selected audio track is
decoded; bitrate/format selection is unchanged. Animated artwork and Spotify
Canvas continue through the separate `video_player` engine.

The app installs `BStreamEqualizer` through the existing `AudioPipeline`, with
one independent ten-band PCM DSP per deck. It does not use Android's vendor
`Equalizer`. The legacy public `AndroidEqualizer` API remains available to
other consumers of the fork, unchanged. No new decoder or Dart PCM processing
is introduced.

`BStreamEqualizerConfiguration` hands immutable ten-band snapshots to the
native audio thread. `BStreamEqualizerAudioProcessor` uses ten Q=1 biquads at
31, 62, 125, 250, 500, 1000, 2000, 4000, 8000 and 16000 Hz, with gains from -12 to +12 dB. It applies
combined-response headroom before the filters/quantization and interpolates
changes over 25 ms. One positive band reserves its exact gain. Multiple boosts
use the largest estimated combined Q=1 response across 257 logarithmic points
and all ten centers, plus 0.1 dB, capped by the sum of positive gains. Cuts are
ignored to keep the estimate conservative. This runs once per configuration,
never per sample. Headroom reduces clipping risk without replacing a limiter;
extreme transients can still clip. Bands at or above Nyquist are identity.
Each channel has independent reusable filter history and buffers. Flush/seek
resets history. PCM16, PCM24/32 and float are supported, including the endian
variants recognized by Media3. Disabled/flat bypass preserves input bytes
after an outstanding transition settles.

`BStreamAudioProcessorChain` keeps silence detection and Sonic before EQ.
Media3 1.4.1 skips custom processor chains on high-resolution float output;
`BStreamEqualizerAudioSink` covers that route without changing its encoding,
channels, sample count or timestamps. It preserves original input-buffer
identity under backpressure and never processes a retained buffer twice.
The wrapper delegates PCM16 processing to the normal chain. Registered DSP
players always decline compressed passthrough and disable offload, even when
disabled, so changing the curve never needs a decoder-route restart.

Dart sends aggregate settings with `bstreamEqualizerConfigure` and can query
`bstreamEqualizerReadStatus` over the existing per-player method channel.
`bstreamEqualizerStatusChanged` uses that same channel, without a second
EventChannel or polling timer. Snapshots include the acknowledged curve,
headroom, PCM format, processed-frame count, requested revision and applied
revision; the latter catches up after the 25 ms transition. The service
validates native acknowledgments, serializes updates, and retries incomplete
curves instead of trusting optimistic UI state. Failures bypass DSP while
leaving playback and the user/crossfade volumes independent. Disposal removes
the method handler and status subscription.

JVM tests measure generated PCM frequency response and check formats,
headroom, bypass, channel separation, fragmented buffers, transitions,
Nyquist, flush and high-resolution sink backpressure. Flutter integration
selects every preset through the real settings page, verifies native status
and flowing samples, and exercises stop/restart and source upgrades.

The Android player replaces Media3's default silence detector with BStream's
PCM16 RMS processor. It evaluates 100 ms windows every 25 ms, smooths their
power over 250 ms, enters silence at -52 dBFS and exits at -46 dBFS. At least
90 percent of the candidate windows must vote silent. An unambiguous initial
stream edge needs 1.8 seconds; internal candidates need 4.5 seconds, so three-
and four-second musical pauses remain bit-exact. Media3 also flushes or queues
processor EOS while seeking and changing playback parameters. Without an
explicit real-edge signal those boundaries conservatively use 4.5 seconds;
they are never reclassified as a 1.8-second intro/outro. Removed intervals
retain 150 ms before and 250 ms after the splice, with a 20 ms sample-domain
fade on each side.

The 800 ms fade protection is an entry guard, not another 800 ms of padding:
a removable candidate must contain an uninterrupted 800 ms run below the
entry threshold, and this run is included in the 1.8/4.5 second minimum. A
window at or above -46 dBFS cancels immediately. Independently, the previous
music-safe peak veto is retained inside the RMS-silent region: a 100 ms window
that would vote at or below -52 dBFS instead cancels the candidate when its PCM
magnitude exceeds 64. Peaks do not override the -52..-46 dBFS hysteresis band.
This protects sparse ambience, reverb, and a low sine with peak 80 that pure
RMS would classify as silence without reducing the detector to the old peak
threshold. PCM through the most recent hard-veto evidence is also a protected
lookbehind prefix: a later silent candidate may consume only the suffix after
that boundary, so a short peak cannot be removed retroactively.
The peak veto is maintained as a rolling count, so evaluating it stays O(1)
per analysis hop even while a device scans several minutes of silence faster
than real time.

The processor drops decoded PCM instead of seeking. Its skipped-frame counter
feeds Media3's `AudioProcessorChain`, preserving the original media timeline
used by position reporting and crossfade. Because preserving a sub-4.5-second
pause while removing an interval only after it crosses that limit causally
requires 4.5 seconds of lookahead, BStream's Android load control preloads 5
seconds both initially and after a rebuffer. This playback prebuffer is
independent of the 3 MiB InnerTube URL-validity probe/offset.

While the detector continuously removes a long interval, Media3 coalesces its
silence discontinuity notifications until skipping pauses. The Android bridge
therefore samples the authoritative native media clock every 200 ms while the
option is enabled and publishes only after it runs at least 200 ms ahead of
Dart's real-time extrapolation. Long skips and repeated backward seeks remain
visually synchronized. Ordinary buffered-position notifications retain their
500 ms rate limit, so the faster clock sampling does not increase bridge events
when no silence is being removed.

The buffered-position watcher sleeps whenever a ready deck is not loading and
does not need silence-skipping clock correction. Media3's loading callback
publishes the final buffered position and restarts the watcher on a refill;
play/pause and silence-option changes also refresh that decision. A paused
crossfade standby no longer polls an unchanged buffer every second. Ordinary
position interpolation and native queue/crossfade transitions stay independent
of this buffer watcher.

The customization is isolated in
`BStreamSilenceSkippingProfile.java` and
`BStreamSilenceSkippingAudioProcessor.java`, and is covered by Android unit
and Flutter emulator integration tests. Media3 remains strictly pinned to
1.4.1; upgrading it requires rerunning the clock, channel-count, edge, and
crossfade tests.
