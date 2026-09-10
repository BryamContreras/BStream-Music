package com.ryanheise.just_audio;

/** Music-safe RMS silence skipping parameters used by BStream on Android. */
final class BStreamSilenceSkippingProfile {
    static final long ANALYSIS_WINDOW_US = 100_000L;
    static final long ANALYSIS_HOP_US = 25_000L;
    static final long RMS_SMOOTHING_US = 250_000L;

    static final double ENTER_SILENCE_DBFS = -52.0;
    static final double EXIT_SILENCE_DBFS = -46.0;
    static final int REQUIRED_SILENT_WINDOW_PERCENTAGE = 90;

    /**
     * Independent music guard inherited from the previous detector. A 100 ms
     * window containing a PCM16 peak above this value cannot vote as silence,
     * even when its RMS is below the entry threshold.
     */
    static final short MUSICAL_PEAK_GUARD_LEVEL = 64;

    /** Only stream edges may use the shorter threshold. */
    static final long EDGE_MINIMUM_SILENCE_DURATION_US = 1_800_000L;

    /** Internal musical pauses shorter than this are always emitted unchanged. */
    static final long INTERNAL_MINIMUM_SILENCE_DURATION_US = 4_500_000L;

    static final long LEADING_SILENCE_TO_KEEP_US = 150_000L;
    static final long TRAILING_SILENCE_TO_KEEP_US = 250_000L;

    /**
     * Entry guard, not extra padding: at least one uninterrupted block this long
     * must remain below the entry threshold before a candidate can be removed.
     * The normal minimum duration still includes this interval.
     */
    static final long FADE_PROTECTION_DURATION_US = 800_000L;

    /** Sample-domain fade at each side of a removed interval. */
    static final long SPLICE_FADE_DURATION_US = 20_000L;

    private BStreamSilenceSkippingProfile() {}

    static BStreamSilenceSkippingAudioProcessor createProcessor() {
        return new BStreamSilenceSkippingAudioProcessor();
    }
}
