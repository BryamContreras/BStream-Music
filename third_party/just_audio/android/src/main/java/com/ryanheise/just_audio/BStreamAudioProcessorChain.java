package com.ryanheise.just_audio;

import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessorChain;
import androidx.media3.common.audio.SonicAudioProcessor;

/** The standard Media3 processor chain with BStream's music-safe detector. */
final class BStreamAudioProcessorChain implements AudioProcessorChain {
    private final BStreamSilenceSkippingAudioProcessor silenceSkippingAudioProcessor;
    private final SonicAudioProcessor sonicAudioProcessor;
    private final AudioProcessor[] audioProcessors;

    BStreamAudioProcessorChain() {
        silenceSkippingAudioProcessor = BStreamSilenceSkippingProfile.createProcessor();
        sonicAudioProcessor = new SonicAudioProcessor();
        audioProcessors = new AudioProcessor[] {
            silenceSkippingAudioProcessor,
            sonicAudioProcessor,
        };
    }

    @Override
    public AudioProcessor[] getAudioProcessors() {
        return audioProcessors;
    }

    @Override
    public PlaybackParameters applyPlaybackParameters(PlaybackParameters playbackParameters) {
        sonicAudioProcessor.setSpeed(playbackParameters.speed);
        sonicAudioProcessor.setPitch(playbackParameters.pitch);
        return playbackParameters;
    }

    @Override
    public boolean applySkipSilenceEnabled(boolean skipSilenceEnabled) {
        silenceSkippingAudioProcessor.setEnabled(skipSilenceEnabled);
        return skipSilenceEnabled;
    }

    @Override
    public long getMediaDuration(long playoutDuration) {
        return sonicAudioProcessor.isActive()
            ? sonicAudioProcessor.getMediaDuration(playoutDuration)
            : playoutDuration;
    }

    @Override
    public long getSkippedOutputFrameCount() {
        return silenceSkippingAudioProcessor.getSkippedFrames();
    }
}
