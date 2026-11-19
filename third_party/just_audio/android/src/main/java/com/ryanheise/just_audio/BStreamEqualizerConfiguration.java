package com.ryanheise.just_audio;

import java.util.Arrays;

/** Immutable parameter handoff from Flutter's thread to each deck's audio thread. */
final class BStreamEqualizerConfiguration {
    static final double[] FREQUENCIES = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};
    static final double MIN_GAIN_DB = -12;
    static final double MAX_GAIN_DB = 12;

    static final class Snapshot {
        final boolean enabled;
        final double[] gainsDb;
        final long revision;
        final double preampDb;

        Snapshot(boolean enabled, double[] gainsDb, long revision) {
            this.enabled = enabled;
            this.gainsDb = gainsDb.clone();
            this.revision = revision;
            preampDb = headroomDb(this.gainsDb);
        }

        boolean active() {
            if (!enabled) return false;
            for (double gain : gainsDb) if (Math.abs(gain) >= 0.01) return true;
            return false;
        }
    }

    /** Conservative combined response estimate, computed only for a new snapshot. */
    private static double headroomDb(double[] gainsDb) {
        double total = 0;
        int boosts = 0;
        double[] amplitudeSquared = new double[FREQUENCIES.length];
        for (int band = 0; band < FREQUENCIES.length; band++) {
            if (gainsDb[band] < .01) continue;
            total += gainsDb[band];
            boosts++;
            amplitudeSquared[band] = Math.pow(10, gainsDb[band] / 20);
        }
        if (boosts < 2) return -total;
        double maximum = 0;
        double start = Math.log(FREQUENCIES[0]);
        double range = Math.log(FREQUENCIES[FREQUENCIES.length - 1]) - start;
        for (int point = 0; point <= 256 + FREQUENCIES.length; point++) {
            double frequency = point <= 256
                    ? Math.exp(start + range * point / 256.0)
                    : FREQUENCIES[point - 257];
            double response = 0;
            for (int band = 0; band < FREQUENCIES.length; band++) {
                double a2 = amplitudeSquared[band];
                if (a2 == 0) continue;
                double ratio = frequency / FREQUENCIES[band];
                double r2 = ratio * ratio;
                double difference = 1 - r2;
                double d = difference * difference;
                response += 10 * Math.log10((d + r2 * a2) / (d + r2 / a2));
            }
            maximum = Math.max(maximum, response);
        }
        return -Math.min(total, maximum + .1);
    }

    private volatile Snapshot current = new Snapshot(false, new double[FREQUENCIES.length], 0);
    private volatile boolean configured;
    private volatile boolean available = true;
    private volatile String failure;
    private volatile Object formatOwner;
    private volatile long routeGeneration;
    private volatile Runnable statusListener;
    private volatile int sampleRate;
    private volatile int channelCount;
    private volatile int encoding;
    private volatile long processedFrames;
    private volatile long appliedRevision;

    Snapshot snapshot() { return current; }
    boolean isActive() { return current.active(); }

    synchronized void configure(boolean enabled, double[] gainsDb) {
        if (gainsDb.length != FREQUENCIES.length) throw new IllegalArgumentException("Equalizer needs ten bands");
        double[] normalized = gainsDb.clone();
        for (int i = 0; i < normalized.length; i++) {
            if (!Double.isFinite(normalized[i])) {
                throw new IllegalArgumentException("Equalizer gains must be finite");
            }
            normalized[i] = Math.max(MIN_GAIN_DB, Math.min(MAX_GAIN_DB, normalized[i]));
        }
        Snapshot previous = current;
        if (previous.enabled == enabled && Arrays.equals(previous.gainsDb, normalized)) return;
        current = new Snapshot(enabled, normalized, previous.revision + 1);
    }

    synchronized void beginRoute() {
        routeGeneration++;
        formatOwner = null;
        boolean changed = configured;
        clearFormat();
        if (changed) notifyStatus();
    }

    long routeGeneration() { return routeGeneration; }

    void configured(Object owner, int sampleRate, int channelCount, int encoding) {
        configured(owner, routeGeneration, sampleRate, channelCount, encoding);
    }

    synchronized void configured(Object owner, long generation, int sampleRate, int channelCount, int encoding) {
        if (generation != routeGeneration) return;
        boolean changed = !configured || !available || this.sampleRate != sampleRate ||
                this.channelCount != channelCount || this.encoding != encoding;
        formatOwner = owner;
        this.sampleRate = sampleRate;
        this.channelCount = channelCount;
        this.encoding = encoding;
        configured = true;
        available = true;
        failure = null;
        if (changed) notifyStatus();
    }

    void ensureConfigured(Object owner, long generation, int sampleRate, int channelCount, int encoding) {
        // One cheap check per buffer, not a callback/poll per sample. A retired
        // pipeline can reset after a new route was configured; the processor
        // actually handling PCM remains the authoritative owner.
        if (generation == routeGeneration && (formatOwner != owner || !configured || !available ||
                this.sampleRate != sampleRate || this.channelCount != channelCount ||
                this.encoding != encoding)) {
            configured(owner, generation, sampleRate, channelCount, encoding);
        }
    }

    void unconfigured(Object owner) {
        unconfigured(owner, routeGeneration);
    }

    synchronized void unconfigured(Object owner, long generation) {
        if (generation != routeGeneration || formatOwner != owner) return;
        formatOwner = null;
        boolean changed = configured;
        clearFormat();
        if (changed) notifyStatus();
    }

    synchronized void unavailable(String reason) {
        boolean changed = available || configured;
        available = false;
        failure = reason;
        formatOwner = null;
        clearFormat();
        if (changed) notifyStatus();
    }

    private void clearFormat() {
        configured = false;
        sampleRate = channelCount = encoding = 0;
        appliedRevision = -1;
    }

    void setStatusListener(Runnable listener) {
        statusListener = listener;
    }

    private void notifyStatus() {
        Runnable listener = statusListener;
        if (listener != null) listener.run();
    }

    void processed(int frames, long appliedRevision) {
        processed(frames, appliedRevision, routeGeneration);
    }

    void processed(int frames, long appliedRevision, long generation) {
        processedFrames += frames;
        if (generation == routeGeneration) this.appliedRevision = appliedRevision;
    }

    boolean isConfigured() { return configured; }
    boolean isAvailable() { return available; }
    String failure() { return failure; }
    int sampleRate() { return sampleRate; }
    int channelCount() { return channelCount; }
    int encoding() { return encoding; }
    long processedFrames() { return processedFrames; }
    long appliedRevision() { return appliedRevision; }
}
