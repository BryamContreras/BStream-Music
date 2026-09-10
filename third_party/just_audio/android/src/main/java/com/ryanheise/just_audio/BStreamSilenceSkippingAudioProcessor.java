package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;

/**
 * Streaming PCM16 silence remover used by BStream.
 *
 * <p>The detector measures an RMS-like envelope without square roots or logarithms: every audio
 * frame contributes the greatest squared sample among its channels, a 100 ms moving mean is
 * sampled every 25 ms, and ten such values form the 250 ms smoothed power. Taking the greatest
 * channel makes a centre-only or otherwise sparse multichannel signal as safe as mono.</p>
 *
 * <p>A separate peak guard preserves very quiet tonal material that RMS alone would mistake for
 * silence. No media seek is performed. Removed PCM frames are reported through {@link
 * #getSkippedFrames()}, which lets {@code DefaultAudioSink} keep Media3's source clock and
 * crossfade scheduling on the original media timeline.</p>
 */
final class BStreamSilenceSkippingAudioProcessor implements AudioProcessor {
    private RmsProcessor activeProcessor;
    private RmsProcessor pendingProcessor;
    private boolean enabled;

    void setEnabled(boolean enabled) {
        this.enabled = enabled;
        if (activeProcessor != null) {
            activeProcessor.setEnabled(enabled);
        }
        if (pendingProcessor != null) {
            pendingProcessor.setEnabled(enabled);
        }
    }

    long getSkippedFrames() {
        return activeProcessor == null ? 0 : activeProcessor.getSkippedFrames();
    }

    @Override
    public AudioFormat configure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        RmsProcessor candidate = new RmsProcessor();
        candidate.setEnabled(enabled);
        AudioFormat outputAudioFormat = candidate.configure(inputAudioFormat);
        if (pendingProcessor != null) {
            pendingProcessor.reset();
        }
        pendingProcessor = candidate;
        return outputAudioFormat;
    }

    @Override
    public boolean isActive() {
        if (pendingProcessor != null) {
            return pendingProcessor.isActive();
        }
        return activeProcessor != null && activeProcessor.isActive();
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        requireActiveProcessor().queueInput(inputBuffer);
    }

    @Override
    public void queueEndOfStream() {
        requireActiveProcessor().queueEndOfStream();
    }

    @Override
    public ByteBuffer getOutput() {
        return activeProcessor == null
            ? AudioProcessor.EMPTY_BUFFER
            : activeProcessor.getOutput();
    }

    @Override
    public boolean isEnded() {
        return activeProcessor == null || activeProcessor.isEnded();
    }

    @Override
    public void flush() {
        if (pendingProcessor != null) {
            if (activeProcessor != null) {
                activeProcessor.reset();
            }
            activeProcessor = pendingProcessor;
            pendingProcessor = null;
        }
        if (activeProcessor != null) {
            activeProcessor.setEnabled(enabled);
            activeProcessor.flush();
        }
    }

    @Override
    public void reset() {
        if (activeProcessor != null) {
            activeProcessor.reset();
        }
        if (pendingProcessor != null) {
            pendingProcessor.reset();
        }
        activeProcessor = null;
        pendingProcessor = null;
        enabled = false;
    }

    private RmsProcessor requireActiveProcessor() {
        if (activeProcessor == null) {
            throw new IllegalStateException("Silence processor was not configured and flushed");
        }
        return activeProcessor;
    }

    private static final class RmsProcessor extends BaseAudioProcessor {
        private static final int ENVELOPE_NOT_READY = 0;
        private static final int ENVELOPE_SILENT = 1;
        private static final int ENVELOPE_HYSTERESIS = 2;
        private static final int ENVELOPE_NOISY = 3;
        private static final int ENVELOPE_MUSICAL_PEAK = 4;

        private static final double PCM16_FULL_SCALE_POWER = 32768.0 * 32768.0;
        private static final double ENTER_SILENCE_POWER = dbfsToPower(
            BStreamSilenceSkippingProfile.ENTER_SILENCE_DBFS);
        private static final double EXIT_SILENCE_POWER = dbfsToPower(
            BStreamSilenceSkippingProfile.EXIT_SILENCE_DBFS);
        private static final long MUSICAL_PEAK_GUARD_POWER =
            (long) BStreamSilenceSkippingProfile.MUSICAL_PEAK_GUARD_LEVEL
                * BStreamSilenceSkippingProfile.MUSICAL_PEAK_GUARD_LEVEL;

        private boolean enabled;
        private int bytesPerFrame;
        private int analysisWindowFrames;
        private int analysisHopFrames;
        private int smoothingWindowCount;
        private int fadeProtectionWindowCount;
        private int analysisContextWindowCount;
        private int edgeMinimumFrames;
        private int internalMinimumFrames;
        private int leadingKeepFrames;
        private int trailingKeepFrames;
        private int spliceFadeFrames;

        private long[] framePowerRing = new long[0];
        private int framePowerRingIndex;
        private int framePowerRingSize;
        private long framePowerSum;
        private long analyzedFrameCount;
        private long lastProtectedEvidenceFrame;

        private double[] windowPowerRing = new double[0];
        private int windowPowerRingIndex;
        private int windowPowerRingSize;
        private double windowPowerSum;

        private final ByteAccumulator candidate = new ByteAccumulator();
        private final ByteAccumulator output = new ByteAccumulator();
        private CircularByteBuffer analysisLookbehind = CircularByteBuffer.empty();
        private CircularByteBuffer trailingSilence = CircularByteBuffer.empty();

        private boolean candidateActive;
        private boolean candidateConfirmed;
        private boolean candidateIsIntro;
        private boolean hasFlushed;
        private int candidateWindowCount;
        private int candidateSilentWindowCount;
        private int consecutiveSilentWindowCount;
        private int longestSilentWindowRun;
        private int inactiveHysteresisWindowCount;
        // Prefix of analysisLookbehind ending at the newest raw PCM evidence behind a hard veto.
        // It must be emitted unchanged before any later candidate can absorb the remainder.
        private int protectedLookbehindBytes;
        private long skippedFrames;

        void setEnabled(boolean enabled) {
            this.enabled = enabled;
        }

        long getSkippedFrames() {
            return skippedFrames;
        }

        @Override
        protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
                throws UnhandledAudioFormatException {
            if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
                    || inputAudioFormat.sampleRate == Format.NO_VALUE
                    || inputAudioFormat.sampleRate <= 0
                    || inputAudioFormat.channelCount <= 0) {
                throw new UnhandledAudioFormatException(inputAudioFormat);
            }
            return inputAudioFormat;
        }

        @Override
        public boolean isActive() {
            return super.isActive() && enabled;
        }

        @Override
        protected void onFlush() {
            bytesPerFrame = inputAudioFormat.bytesPerFrame;
            analysisWindowFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.ANALYSIS_WINDOW_US);
            analysisHopFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.ANALYSIS_HOP_US);
            smoothingWindowCount = divideRoundingUp(
                BStreamSilenceSkippingProfile.RMS_SMOOTHING_US,
                BStreamSilenceSkippingProfile.ANALYSIS_HOP_US);
            fadeProtectionWindowCount = divideRoundingUp(
                BStreamSilenceSkippingProfile.FADE_PROTECTION_DURATION_US,
                BStreamSilenceSkippingProfile.ANALYSIS_HOP_US);
            edgeMinimumFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.EDGE_MINIMUM_SILENCE_DURATION_US);
            internalMinimumFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.INTERNAL_MINIMUM_SILENCE_DURATION_US);
            leadingKeepFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.LEADING_SILENCE_TO_KEEP_US);
            trailingKeepFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.TRAILING_SILENCE_TO_KEEP_US);
            spliceFadeFrames = durationUsToFrames(
                BStreamSilenceSkippingProfile.SPLICE_FADE_DURATION_US);

            if (framePowerRing.length != analysisWindowFrames) {
                framePowerRing = new long[analysisWindowFrames];
            }
            if (windowPowerRing.length != smoothingWindowCount) {
                windowPowerRing = new double[smoothingWindowCount];
            }
            int analysisContextFrames = analysisWindowFrames
                + (smoothingWindowCount - 1) * analysisHopFrames;
            analysisContextWindowCount = divideRoundingUp(
                analysisContextFrames,
                analysisHopFrames);
            analysisLookbehind.resetCapacity(analysisContextFrames * bytesPerFrame);
            trailingSilence.resetCapacity(trailingKeepFrames * bytesPerFrame);

            framePowerRingIndex = 0;
            framePowerRingSize = 0;
            framePowerSum = 0;
            analyzedFrameCount = 0;
            lastProtectedEvidenceFrame = 0;
            windowPowerRingIndex = 0;
            windowPowerRingSize = 0;
            windowPowerSum = 0;
            candidate.clear();
            output.clear();
            analysisLookbehind.clear();
            trailingSilence.clear();
            skippedFrames = 0;
            inactiveHysteresisWindowCount = 0;
            protectedLookbehindBytes = 0;

            // Only the first activation of this freshly configured processor is an unambiguous
            // stream edge. Media3 also flushes processors after seeks and parameter/toggle
            // changes; treating those flushes as intros would lower the internal 4.5 s guard to
            // 1.8 s in the middle of music.
            boolean isInitialEdge = !hasFlushed;
            hasFlushed = true;
            startCandidate(/* isIntro= */ isInitialEdge);
        }

        @Override
        public void queueInput(ByteBuffer inputBuffer) {
            if (hasPendingOutput()) {
                return;
            }
            if (inputBuffer.remaining() % bytesPerFrame != 0) {
                throw new IllegalArgumentException("PCM input is not aligned to an audio frame");
            }

            output.clear();
            while (inputBuffer.hasRemaining()) {
                int framePosition = inputBuffer.position();
                int envelope = analyzeFrame(inputBuffer, framePosition);
                boolean hardVeto = cancelsCandidate(envelope);

                if (hardVeto) {
                    if (candidateActive) {
                        finishCandidateAtNoise();
                    }
                    inactiveHysteresisWindowCount = 0;
                } else if (!candidateActive) {
                    if (envelope == ENVELOPE_SILENT) {
                        startInternalCandidate();
                    } else if (envelope == ENVELOPE_HYSTERESIS) {
                        inactiveHysteresisWindowCount = Math.min(
                            analysisContextWindowCount,
                            inactiveHysteresisWindowCount + 1);
                    }
                }

                if (candidateActive && envelope != ENVELOPE_NOT_READY
                        && !cancelsCandidate(envelope)) {
                    recordCandidateWindow(envelope == ENVELOPE_SILENT);
                }

                if (candidateActive) {
                    if (candidateConfirmed) {
                        appendConfirmedFrame(inputBuffer, framePosition);
                    } else {
                        candidate.append(inputBuffer, framePosition, bytesPerFrame);
                    }
                } else {
                    appendNormalFrame(inputBuffer, framePosition);
                }
                inputBuffer.position(framePosition + bytesPerFrame);

                if (hardVeto) {
                    // Protect every still-deferred byte through the newest raw PCM evidence in
                    // the envelope history. A later silent window may start a candidate from the
                    // suffix, but it cannot retroactively remove the evidence that caused this
                    // veto. Using the evidence frame rather than this delayed envelope decision
                    // also keeps the requested leading margin exact.
                    protectedLookbehindBytes = protectedPrefixThroughLatestEvidence();
                }

                if (candidateActive && !candidateConfirmed
                        && envelope != ENVELOPE_NOT_READY
                        && !cancelsCandidate(envelope)) {
                    resolveCandidateAtMinimum();
                }
            }
            publishOutput();
        }

        @Override
        protected void onQueueEndOfStream() {
            output.clear();
            if (candidateActive) {
                if (!candidateConfirmed) {
                    int minimumFrames = candidateIsIntro
                        ? edgeMinimumFrames
                        : internalMinimumFrames;
                    if (candidateQualifies(minimumFrames)) {
                        confirmCandidate();
                    } else {
                        preserveCandidate();
                    }
                }
                if (candidateConfirmed) {
                    finishConfirmedCandidate();
                }
                candidateActive = false;
            }
            analysisLookbehind.drainTo(output);
            protectedLookbehindBytes = 0;
            publishOutput();
        }

        @Override
        protected void onReset() {
            enabled = false;
            framePowerRing = new long[0];
            framePowerRingIndex = 0;
            framePowerRingSize = 0;
            framePowerSum = 0;
            analyzedFrameCount = 0;
            lastProtectedEvidenceFrame = 0;
            windowPowerRing = new double[0];
            windowPowerRingIndex = 0;
            windowPowerRingSize = 0;
            windowPowerSum = 0;
            candidate.clearAndRelease();
            output.clearAndRelease();
            analysisLookbehind = CircularByteBuffer.empty();
            trailingSilence = CircularByteBuffer.empty();
            candidateActive = false;
            candidateConfirmed = false;
            candidateIsIntro = false;
            hasFlushed = false;
            candidateWindowCount = 0;
            candidateSilentWindowCount = 0;
            consecutiveSilentWindowCount = 0;
            longestSilentWindowRun = 0;
            inactiveHysteresisWindowCount = 0;
            protectedLookbehindBytes = 0;
            skippedFrames = 0;
        }

        private int analyzeFrame(ByteBuffer input, int framePosition) {
            long framePower = 0;
            for (int channel = 0; channel < inputAudioFormat.channelCount; channel++) {
                long sample = input.getShort(framePosition + channel * 2);
                long samplePower = sample * sample;
                framePower = Math.max(framePower, samplePower);
            }

            if (framePowerRingSize < analysisWindowFrames) {
                framePowerRing[framePowerRingIndex] = framePower;
                framePowerSum += framePower;
                framePowerRingSize++;
            } else {
                framePowerSum -= framePowerRing[framePowerRingIndex];
                framePowerRing[framePowerRingIndex] = framePower;
                framePowerSum += framePower;
            }
            framePowerRingIndex = (framePowerRingIndex + 1) % analysisWindowFrames;
            analyzedFrameCount++;
            if (framePower > MUSICAL_PEAK_GUARD_POWER) {
                lastProtectedEvidenceFrame = analyzedFrameCount;
            }

            if (framePowerRingSize < analysisWindowFrames
                    || (analyzedFrameCount - analysisWindowFrames) % analysisHopFrames != 0) {
                return ENVELOPE_NOT_READY;
            }

            double windowPower = (double) framePowerSum / analysisWindowFrames;
            boolean hasMusicalPeak = maximumPowerInAnalysisWindow() > MUSICAL_PEAK_GUARD_POWER;
            if (windowPowerRingSize < smoothingWindowCount) {
                windowPowerRing[windowPowerRingIndex] = windowPower;
                windowPowerSum += windowPower;
                windowPowerRingSize++;
            } else {
                windowPowerSum -= windowPowerRing[windowPowerRingIndex];
                windowPowerRing[windowPowerRingIndex] = windowPower;
                windowPowerSum += windowPower;
            }
            windowPowerRingIndex = (windowPowerRingIndex + 1) % smoothingWindowCount;
            // During the first 250 ms use every window available so a definite signal does not
            // remain trapped merely while the smoothing history warms up.
            double smoothedPower = windowPowerSum / windowPowerRingSize;
            if (smoothedPower >= EXIT_SILENCE_POWER) {
                return ENVELOPE_NOISY;
            }
            if (smoothedPower <= ENTER_SILENCE_POWER) {
                // Preserve the previous detector's quiet-music protection only in the RMS region
                // that would otherwise vote silent. Peaks do not collapse the -52..-46 dBFS
                // hysteresis band back into the old sample threshold.
                if (hasMusicalPeak) {
                    return ENVELOPE_MUSICAL_PEAK;
                }
                return ENVELOPE_SILENT;
            }
            return ENVELOPE_HYSTERESIS;
        }

        private long maximumPowerInAnalysisWindow() {
            long maximum = 0;
            for (int index = 0; index < framePowerRingSize; index++) {
                maximum = Math.max(maximum, framePowerRing[index]);
            }
            return maximum;
        }

        private int protectedPrefixThroughLatestEvidence() {
            if (lastProtectedEvidenceFrame == 0) {
                return 0;
            }
            long framesAfterEvidence = analyzedFrameCount - lastProtectedEvidenceFrame;
            long bytesAfterEvidence = framesAfterEvidence * bytesPerFrame;
            if (bytesAfterEvidence >= analysisLookbehind.size()) {
                return 0;
            }
            return analysisLookbehind.size() - (int) bytesAfterEvidence;
        }

        private static boolean cancelsCandidate(int envelope) {
            return envelope == ENVELOPE_NOISY || envelope == ENVELOPE_MUSICAL_PEAK;
        }

        private void startInternalCandidate() {
            int precedingHysteresisWindows = inactiveHysteresisWindowCount;
            startCandidate(/* isIntro= */ false);
            candidateWindowCount = precedingHysteresisWindows;
            inactiveHysteresisWindowCount = 0;
            int protectedBytes = Math.min(
                protectedLookbehindBytes,
                analysisLookbehind.size());
            analysisLookbehind.drain(output, protectedBytes);
            analysisLookbehind.drainTo(candidate);
            protectedLookbehindBytes = 0;
        }

        private void startCandidate(boolean isIntro) {
            candidate.clear();
            trailingSilence.clear();
            candidateActive = true;
            candidateConfirmed = false;
            candidateIsIntro = isIntro;
            candidateWindowCount = 0;
            candidateSilentWindowCount = 0;
            consecutiveSilentWindowCount = 0;
            longestSilentWindowRun = 0;
        }

        private void recordCandidateWindow(boolean silent) {
            candidateWindowCount++;
            if (silent) {
                candidateSilentWindowCount++;
                consecutiveSilentWindowCount++;
                longestSilentWindowRun = Math.max(
                    longestSilentWindowRun,
                    consecutiveSilentWindowCount);
            } else {
                consecutiveSilentWindowCount = 0;
            }
        }

        private void resolveCandidateAtMinimum() {
            int minimumFrames = candidateIsIntro ? edgeMinimumFrames : internalMinimumFrames;
            int candidateFrames = candidate.frameCount(bytesPerFrame);
            if (candidateFrames < minimumFrames) {
                if (!canStillReachRequiredSilentPercentage(minimumFrames, candidateFrames)) {
                    rejectCandidate();
                }
                return;
            }
            if (candidateQualifies(minimumFrames)) {
                confirmCandidate();
            } else {
                rejectCandidate();
            }
        }

        private boolean canStillReachRequiredSilentPercentage(
                int minimumFrames,
                int candidateFrames) {
            int remainingFrames = minimumFrames - candidateFrames;
            long remainingWindows = divideRoundingUp(remainingFrames, analysisHopFrames);
            long maximumSilentWindows = candidateSilentWindowCount + remainingWindows;
            long finalWindowCount = candidateWindowCount + remainingWindows;
            return finalWindowCount == 0
                || maximumSilentWindows * 100L
                    >= finalWindowCount
                        * (long) BStreamSilenceSkippingProfile.REQUIRED_SILENT_WINDOW_PERCENTAGE;
        }

        private void rejectCandidate() {
            // Emit the failed interval unchanged and let a later low window open a fresh
            // candidate. The impossibility check avoids retaining 1.8 seconds of continuous
            // -52..-46 dBFS material before playback can begin.
            preserveCandidateForContinuation();
            candidateActive = false;
            candidateIsIntro = false;
        }

        private boolean candidateQualifies(int minimumFrames) {
            return candidate.frameCount(bytesPerFrame) >= minimumFrames
                && candidateWindowCount > 0
                && candidateSilentWindowCount * 100L
                    >= candidateWindowCount
                        * (long) BStreamSilenceSkippingProfile.REQUIRED_SILENT_WINDOW_PERCENTAGE
                && longestSilentWindowRun >= fadeProtectionWindowCount;
        }

        private void finishCandidateAtNoise() {
            if (candidateConfirmed) {
                finishConfirmedCandidate();
            } else {
                preserveCandidateForContinuation();
            }
            candidateActive = false;
            candidateIsIntro = false;
        }

        private void confirmCandidate() {
            int totalFrames = candidate.frameCount(bytesPerFrame);
            int leadingFrames = Math.min(leadingKeepFrames, totalFrames);
            int trailingFrames = Math.min(trailingKeepFrames, totalFrames - leadingFrames);
            int framesToSkip = totalFrames - leadingFrames - trailingFrames;
            if (framesToSkip <= 0) {
                preserveCandidateForContinuation();
                candidateActive = false;
                candidateIsIntro = false;
                return;
            }

            appendFadeOut(candidate.data(), leadingFrames);
            int trailingOffset = (totalFrames - trailingFrames) * bytesPerFrame;
            trailingSilence.append(candidate.data(), trailingOffset, trailingFrames * bytesPerFrame);
            skippedFrames += framesToSkip;
            candidate.clear();
            candidateConfirmed = true;
        }

        private void appendConfirmedFrame(ByteBuffer input, int framePosition) {
            if (trailingSilence.remainingCapacity() < bytesPerFrame) {
                trailingSilence.discard(bytesPerFrame);
                skippedFrames++;
            }
            trailingSilence.append(input, framePosition, bytesPerFrame);
        }

        private void finishConfirmedCandidate() {
            byte[] tail = trailingSilence.toByteArray();
            int tailFrames = tail.length / bytesPerFrame;
            appendFadeIn(tail, tailFrames);
            trailingSilence.clear();
            candidateConfirmed = false;
        }

        private void preserveCandidate() {
            output.append(candidate.data(), 0, candidate.size());
            candidate.clear();
            trailingSilence.clear();
            candidateConfirmed = false;
        }

        private void preserveCandidateForContinuation() {
            // Keep the normal analysis lookbehind populated when a false candidate is emitted.
            // Otherwise a short prefix could reach AudioTrack and then be followed by a 325 ms
            // starvation gap while the lookbehind fills again.
            int deferredBytes = Math.min(candidate.size(), analysisLookbehind.capacity());
            int immediateBytes = candidate.size() - deferredBytes;
            output.append(candidate.data(), 0, immediateBytes);
            analysisLookbehind.clear();
            analysisLookbehind.append(candidate.data(), immediateBytes, deferredBytes);
            protectedLookbehindBytes = 0;
            candidate.clear();
            trailingSilence.clear();
            candidateConfirmed = false;
        }

        private void appendNormalFrame(ByteBuffer input, int framePosition) {
            if (analysisLookbehind.remainingCapacity() < bytesPerFrame) {
                analysisLookbehind.drain(output, bytesPerFrame);
                protectedLookbehindBytes = Math.max(
                    0,
                    protectedLookbehindBytes - bytesPerFrame);
            }
            analysisLookbehind.append(input, framePosition, bytesPerFrame);
        }

        private void appendFadeOut(byte[] source, int frameCount) {
            int fadeFrames = Math.min(spliceFadeFrames, frameCount);
            int unchangedFrames = frameCount - fadeFrames;
            output.append(source, 0, unchangedFrames * bytesPerFrame);
            appendGainRamp(
                source,
                unchangedFrames * bytesPerFrame,
                fadeFrames,
                /* fadeIn= */ false);
        }

        private void appendFadeIn(byte[] source, int frameCount) {
            int fadeFrames = Math.min(spliceFadeFrames, frameCount);
            appendGainRamp(source, 0, fadeFrames, /* fadeIn= */ true);
            output.append(
                source,
                fadeFrames * bytesPerFrame,
                (frameCount - fadeFrames) * bytesPerFrame);
        }

        private void appendGainRamp(
                byte[] source,
                int sourceOffset,
                int frameCount,
                boolean fadeIn) {
            if (frameCount == 0) {
                return;
            }
            int denominator = Math.max(1, frameCount - 1);
            for (int frame = 0; frame < frameCount; frame++) {
                int numerator = fadeIn ? frame : frameCount - 1 - frame;
                int frameOffset = sourceOffset + frame * bytesPerFrame;
                for (int channelOffset = 0; channelOffset < bytesPerFrame; channelOffset += 2) {
                    int sampleOffset = frameOffset + channelOffset;
                    int sample = (short) ((source[sampleOffset] & 0xFF)
                        | (source[sampleOffset + 1] << 8));
                    int adjusted = (int) Math.round((double) sample * numerator / denominator);
                    output.append((byte) adjusted);
                    output.append((byte) (adjusted >> 8));
                }
            }
        }

        private void publishOutput() {
            if (output.size() == 0) {
                return;
            }
            ByteBuffer outputBuffer = replaceOutputBuffer(output.size());
            outputBuffer.put(output.data(), 0, output.size()).flip();
            output.clear();
        }

        private int durationUsToFrames(long durationUs) {
            long frames = (durationUs * inputAudioFormat.sampleRate + 999_999L) / 1_000_000L;
            if (frames <= 0 || frames > Integer.MAX_VALUE) {
                throw new IllegalStateException("Invalid silence duration for audio format");
            }
            return (int) frames;
        }

        private static int divideRoundingUp(long numerator, long denominator) {
            return (int) ((numerator + denominator - 1) / denominator);
        }

        private static double dbfsToPower(double dbfs) {
            return PCM16_FULL_SCALE_POWER * Math.pow(10.0, dbfs / 10.0);
        }
    }

    /** A grow-only staging buffer whose allocation is retained across calls. */
    private static final class ByteAccumulator {
        private byte[] data = new byte[0];
        private int size;

        byte[] data() {
            return data;
        }

        int size() {
            return size;
        }

        int frameCount(int bytesPerFrame) {
            return size / bytesPerFrame;
        }

        void append(byte value) {
            ensureCapacity(size + 1);
            data[size++] = value;
        }

        void append(byte[] source, int offset, int length) {
            if (length == 0) {
                return;
            }
            ensureCapacity(size + length);
            System.arraycopy(source, offset, data, size, length);
            size += length;
        }

        void append(ByteBuffer source, int offset, int length) {
            ensureCapacity(size + length);
            for (int index = 0; index < length; index++) {
                data[size + index] = source.get(offset + index);
            }
            size += length;
        }

        void clear() {
            size = 0;
        }

        void clearAndRelease() {
            data = new byte[0];
            size = 0;
        }

        private void ensureCapacity(int requiredCapacity) {
            if (requiredCapacity <= data.length) {
                return;
            }
            int grownCapacity = Math.max(requiredCapacity, Math.max(8_192, data.length * 2));
            byte[] grown = new byte[grownCapacity];
            System.arraycopy(data, 0, grown, 0, size);
            data = grown;
        }
    }

    /** Fixed-size byte FIFO used for analysis lookbehind and trailing splice padding. */
    private static final class CircularByteBuffer {
        private byte[] data;
        private int start;
        private int size;

        private CircularByteBuffer(int capacity) {
            data = new byte[capacity];
        }

        static CircularByteBuffer empty() {
            return new CircularByteBuffer(0);
        }

        int remainingCapacity() {
            return data.length - size;
        }

        int capacity() {
            return data.length;
        }

        int size() {
            return size;
        }

        void resetCapacity(int capacity) {
            if (data.length != capacity) {
                data = new byte[capacity];
            }
            clear();
        }

        void append(byte[] source, int offset, int length) {
            ensureCanAppend(length);
            int writePosition = (start + size) % data.length;
            int firstLength = Math.min(length, data.length - writePosition);
            System.arraycopy(source, offset, data, writePosition, firstLength);
            System.arraycopy(source, offset + firstLength, data, 0, length - firstLength);
            size += length;
        }

        void append(ByteBuffer source, int offset, int length) {
            ensureCanAppend(length);
            int writePosition = (start + size) % data.length;
            for (int index = 0; index < length; index++) {
                data[(writePosition + index) % data.length] = source.get(offset + index);
            }
            size += length;
        }

        void drain(ByteAccumulator destination, int length) {
            if (length < 0 || length > size) {
                throw new IllegalArgumentException("Invalid circular buffer drain length");
            }
            int firstLength = Math.min(length, data.length - start);
            destination.append(data, start, firstLength);
            destination.append(data, 0, length - firstLength);
            discard(length);
        }

        void drainTo(ByteAccumulator destination) {
            drain(destination, size);
        }

        void discard(int length) {
            if (length < 0 || length > size) {
                throw new IllegalArgumentException("Invalid circular buffer discard length");
            }
            if (data.length != 0) {
                start = (start + length) % data.length;
            }
            size -= length;
            if (size == 0) {
                start = 0;
            }
        }

        byte[] toByteArray() {
            byte[] result = new byte[size];
            int firstLength = Math.min(size, data.length - start);
            System.arraycopy(data, start, result, 0, firstLength);
            System.arraycopy(data, 0, result, firstLength, size - firstLength);
            return result;
        }

        void clear() {
            start = 0;
            size = 0;
        }

        private void ensureCanAppend(int length) {
            if (length < 0 || length > remainingCapacity()) {
                throw new IllegalStateException("Circular audio buffer overflow");
            }
        }
    }
}
