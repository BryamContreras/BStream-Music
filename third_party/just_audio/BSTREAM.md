# BStream Android customization

This directory vendors `just_audio` 0.10.6 under its original BSD-3-Clause
license. BStream keeps the public Dart API and all non-Android implementations
unchanged.

The small `BStreamAudioOutput` native facade shares a media-output preference
across the active and standby/crossfade players using weak references. It calls
Media3's `setPreferredAudioDevice` on existing engines and reapplies the choice
when an engine is initialized. A disconnected/invalid device falls back to the
system default. This is a best-effort AudioTrack preference, not a promise from
the hardware; no communication mode, SCO or global Bluetooth setting is used.
The app's native output menu controls Android's media stream volume separately
from the player's per-track gain. The public just_audio Dart API is unchanged.

The Android audio engine explicitly disables Media3 video-track selection.
A resolver may return a muxed container, but only its selected audio track is
decoded; bitrate/format selection is unchanged. Animated artwork and Spotify
Canvas continue through the separate `video_player` engine.

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
