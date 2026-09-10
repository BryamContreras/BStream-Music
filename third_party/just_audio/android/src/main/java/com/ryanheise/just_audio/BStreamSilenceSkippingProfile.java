package com.ryanheise.just_audio;

/** Music-safe silence skipping parameters used by BStream on Android. */
final class BStreamSilenceSkippingProfile {
    /** Musical pauses of four seconds or less must remain untouched. */
    static final long MINIMUM_SILENCE_DURATION_US = 4_500_000L;

    /** Keep a substantial part of longer silence instead of cutting to an edge. */
    static final float SILENCE_RETENTION_RATIO = 0.40f;

    /** Long gaps retain up to six seconds, providing a natural audible margin. */
    static final long MAX_SILENCE_TO_KEEP_DURATION_US = 6_000_000L;

    /** Fade retained near-silence to no less than 20% before restoring it. */
    static final int MIN_VOLUME_TO_KEEP_PERCENTAGE = 20;

    /** Approximately -54 dBFS for signed 16-bit PCM. */
    static final short SILENCE_THRESHOLD_LEVEL = 64;

    private BStreamSilenceSkippingProfile() {}

    static BStreamSilenceSkippingAudioProcessor createProcessor() {
        return new BStreamSilenceSkippingAudioProcessor();
    }
}
