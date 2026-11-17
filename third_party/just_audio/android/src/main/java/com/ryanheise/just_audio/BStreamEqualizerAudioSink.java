package com.ryanheise.just_audio;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.util.Util;
import androidx.media3.exoplayer.audio.AudioOffloadSupport;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/**
 * Runs only the high-resolution branch which Media3 1.4's processor chain bypasses.
 * The ordinary PCM16 branch owns its own EQ after silence skipping and Sonic.
 * Encodings, frame counts, timestamps and the delegate's clock remain unchanged.
 */
final class BStreamEqualizerAudioSink extends ForwardingAudioSink {

    private final BStreamEqualizerAudioProcessor processor;
    private final BStreamEqualizerConfiguration configuration;
    private final boolean floatOutput;
    private boolean highResolutionDsp;

    @Nullable private ByteBuffer pendingInput;
    @Nullable private ByteBuffer pendingOutput;
    private long pendingPresentationTimeUs;
    private int pendingAccessUnitCount;

    BStreamEqualizerAudioSink(
            AudioSink delegate,
            BStreamEqualizerConfiguration configuration,
            boolean floatOutput) {
        super(delegate);
        this.configuration = configuration;
        this.processor = new BStreamEqualizerAudioProcessor(configuration);
        this.floatOutput = floatOutput;
    }

    @Override
    public boolean supportsFormat(Format format) {
        return getFormatSupport(format) != SINK_FORMAT_UNSUPPORTED;
    }

    @Override
    public int getFormatSupport(Format format) {
        // Keep this renderer on decoded PCM, including while the EQ is off.
        // Enabling a curve can then take effect without replacing the decoder.
        if (!MimeTypes.AUDIO_RAW.equals(format.sampleMimeType)) {
            return SINK_FORMAT_UNSUPPORTED;
        }
        // Do not advertise float as native if the delegate would transcode it.
        return super.getFormatSupport(format);
    }

    @Override
    public AudioOffloadSupport getFormatOffloadSupport(Format format) {
        return AudioOffloadSupport.DEFAULT_UNSUPPORTED;
    }

    @Override
    @RequiresApi(29)
    public void setOffloadMode(int offloadMode) {
        super.setOffloadMode(OFFLOAD_MODE_DISABLED);
    }

    @Override
    public void configure(
            Format format, int specifiedBufferSize, @Nullable int[] outputChannels)
            throws AudioSink.ConfigurationException {
        // Preserve Media3's route selection and PCM output policy exactly.
        clearPending();
        // Advance before delegate.configure: Media3 configures the new PCM16
        // chain inside that call while an older pipeline may still drain.
        configuration.beginRoute();
        processor.reset();
        highResolutionDsp = false;
        super.configure(format, specifiedBufferSize, outputChannels);
        if (!floatOutput || !Util.isEncodingHighResolutionPcm(format.pcmEncoding)) {
            return;
        }
        try {
            AudioProcessor.AudioFormat input = new AudioProcessor.AudioFormat(
                    format.sampleRate, format.channelCount, format.pcmEncoding);
            AudioProcessor.AudioFormat output = processor.configure(input);
            if (output.encoding != input.encoding
                    || output.sampleRate != input.sampleRate
                    || output.channelCount != input.channelCount) {
                // An optional DSP must never change what the sink was configured
                // to consume, or force a high-resolution stream down to PCM16.
                processor.reset();
                configuration.unavailable("The high-resolution PCM format is not supported by EQ");
                return;
            }
            processor.flush();
            highResolutionDsp = true;
        } catch (AudioProcessor.UnhandledAudioFormatException error) {
            processor.reset();
            configuration.unavailable("The high-resolution PCM format is not supported by EQ");
        }
    }

    @Override
    public boolean handleBuffer(ByteBuffer input, long presentationTimeUs, int encodedAccessUnitCount)
            throws AudioSink.InitializationException, AudioSink.WriteException {
        if (pendingInput != null) {
            // Media3 retries the same input until we return true. Retain both
            // direct and processed buffers, so toggling EQ between retries can
            // never process a partial buffer twice or change the delegate's input.
            if (pendingInput != input) {
                throw new IllegalArgumentException("Retry the pending audio buffer before a new one");
            }
            return drainPending();
        }
        if (!input.hasRemaining()) return true;

        pendingInput = input;
        pendingPresentationTimeUs = presentationTimeUs;
        pendingAccessUnitCount = encodedAccessUnitCount;
        pendingOutput = input;
        if (highResolutionDsp && !processor.isBypassed()) {
            int position = input.position();
            int byteCount = input.remaining();
            try {
                processor.queueInput(input);
                pendingOutput = processor.getOutput();
                if (input.hasRemaining() || pendingOutput.remaining() != byteCount) {
                    throw new IllegalStateException("EQ must preserve every PCM frame");
                }
            } catch (RuntimeException error) {
                // The processor writes to its own reusable output buffer. The
                // decoder's original PCM can safely continue if optional DSP fails.
                input.position(position);
                pendingOutput = input;
                highResolutionDsp = false;
                processor.reset();
                configuration.unavailable("High-resolution EQ failed while processing PCM");
            }
        }
        return drainPending();
    }

    private boolean drainPending()
            throws AudioSink.InitializationException, AudioSink.WriteException {
        if (pendingOutput == null) return true;
        if (!super.handleBuffer(pendingOutput, pendingPresentationTimeUs, pendingAccessUnitCount)) {
            return false;
        }
        clearPending();
        return true;
    }

    @Override
    public void playToEndOfStream() throws AudioSink.WriteException {
        if (pendingInput != null) {
            try {
                if (!drainPending()) return;
            } catch (AudioSink.InitializationException error) {
                AudioSink.WriteException writeError = new AudioSink.WriteException(
                        error.audioTrackState, error.format, error.isRecoverable);
                writeError.initCause(error);
                throw writeError;
            }
        }
        super.playToEndOfStream();
    }

    @Override
    public boolean isEnded() {
        return pendingInput == null && super.isEnded();
    }

    @Override
    public boolean hasPendingData() {
        return pendingInput != null || super.hasPendingData();
    }

    @Override
    public void flush() {
        clearPending();
        processor.flush();
        super.flush();
    }

    @Override
    public void reset() {
        clearPending();
        highResolutionDsp = false;
        processor.reset();
        super.reset();
    }

    @Override
    public void release() {
        clearPending();
        highResolutionDsp = false;
        processor.reset();
        super.release();
    }

    private void clearPending() {
        pendingInput = null;
        pendingOutput = null;
    }
}
