# BStream Android customization

This directory vendors `just_audio` 0.10.6 under its original BSD-3-Clause
license. BStream keeps the public Dart API and all non-Android implementations
unchanged.

The Android player replaces Media3's default silence detector with a
music-safe profile. Media3's defaults begin shortening after 100 ms and use a
PCM threshold of 1024. BStream instead requires 4.5 continuous seconds below
64 (about -54 dBFS), retains 40 percent of longer gaps up to six seconds, and
uses a 20 percent fade floor. This keeps four-second musical pauses, quiet
instrumentation, ambience, and reverb tails intact while still shortening
genuinely long empty intros, gaps, and outros.

The customization is isolated in `BStreamSilenceSkippingProfile.java` and is
covered by the Android unit and Flutter emulator integration tests. Media3 is
strictly pinned to 1.4.1 because the channel-count adapter intentionally
compensates for that version's PCM buffer-size behavior; upgrading Media3 must
include removing or recalibrating the adapter and rerunning those tests.
