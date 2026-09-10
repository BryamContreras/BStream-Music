package com.ryanheise.just_audio;

import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.audio.SilenceSkippingAudioProcessor;
import java.nio.ByteBuffer;

/**
 * Adapts Media3 1.4.1's detector so the configured minimum duration does not
 * change with the decoded channel count.
 *
 * <p>Media3 1.4.1 sizes its internal PCM buffer as though a frame occupied one
 * byte. PCM16 frames actually occupy {@code channelCount * 2} bytes. Scaling
 * the constructor value here restores the intended duration for mono, stereo,
 * and multichannel streams.</p>
 */
final class BStreamSilenceSkippingAudioProcessor implements AudioProcessor {
    private SilenceSkippingAudioProcessor activeProcessor;
    private SilenceSkippingAudioProcessor pendingProcessor;
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
        long channelAdjustedMinimumUs =
            BStreamSilenceSkippingProfile.MINIMUM_SILENCE_DURATION_US
                * inputAudioFormat.channelCount
                * 2L;
        SilenceSkippingAudioProcessor candidate = new SilenceSkippingAudioProcessor(
            channelAdjustedMinimumUs,
            BStreamSilenceSkippingProfile.SILENCE_RETENTION_RATIO,
            BStreamSilenceSkippingProfile.MAX_SILENCE_TO_KEEP_DURATION_US,
            BStreamSilenceSkippingProfile.MIN_VOLUME_TO_KEEP_PERCENTAGE,
            BStreamSilenceSkippingProfile.SILENCE_THRESHOLD_LEVEL);
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

    private SilenceSkippingAudioProcessor requireActiveProcessor() {
        if (activeProcessor == null) {
            throw new IllegalStateException("Silence processor was not configured and flushed");
        }
        return activeProcessor;
    }
}
