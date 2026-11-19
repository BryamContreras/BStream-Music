package com.ryanheise.just_audio;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.ToInt16PcmAudioProcessor;
import androidx.media3.common.util.Util;
import androidx.media3.exoplayer.audio.AudioOffloadSupport;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;
import java.util.function.Predicate;

/**
 * Runs only the high-resolution branch which Media3 1.4's processor chain bypasses.
 * The ordinary PCM16 branch owns its own EQ after silence skipping and Sonic.
 * Encodings, frame counts, timestamps and the delegate's clock remain unchanged.
 */
final class BStreamEqualizerAudioSink extends ForwardingAudioSink {

    private final BStreamEqualizerAudioProcessor processor;
    private final BStreamEqualizerConfiguration configuration;
    private final boolean floatOutput;
    private final Predicate<Format> acceptsFloat;
    private final ToInt16PcmAudioProcessor toInt16 = new ToInt16PcmAudioProcessor();
    private volatile boolean compatibleProcessingRequired;
    private volatile boolean skipSilenceRequested;
    private volatile PlaybackParameters requestedPlaybackParameters = PlaybackParameters.DEFAULT;
    private volatile boolean highResolutionInput;
    private boolean highResolutionDsp;
    private boolean convertToInt16;
    @Nullable private Format floatFormat;
    private int bufferSize;
    @Nullable private int[] outputChannels;

    @Nullable private ByteBuffer pendingInput;
    @Nullable private ByteBuffer pendingOutput;
    private long pendingPresentationTimeUs;
    private int pendingAccessUnitCount;
    private int pendingInputPosition;

    BStreamEqualizerAudioSink(
            AudioSink delegate,
            BStreamEqualizerConfiguration configuration,
            boolean floatOutput) {
        this(delegate, configuration, floatOutput, format -> true);
    }

    BStreamEqualizerAudioSink(
            AudioSink delegate,
            BStreamEqualizerConfiguration configuration,
            boolean floatOutput,
            Predicate<Format> acceptsFloat) {
        super(delegate);
        this.configuration = configuration;
        this.processor = new BStreamEqualizerAudioProcessor(configuration);
        this.floatOutput = floatOutput;
        this.acceptsFloat = acceptsFloat;
    }

    boolean setPlaybackProcessing(boolean skipSilence, PlaybackParameters parameters) {
        skipSilenceRequested = skipSilence;
        requestedPlaybackParameters = parameters;
        boolean required = skipSilence || !PlaybackParameters.DEFAULT.equals(parameters);
        if (compatibleProcessingRequired == required) return false;
        compatibleProcessingRequired = required;
        return highResolutionInput;
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
        if (format.pcmEncoding == C.ENCODING_PCM_FLOAT && !acceptsFloat.test(format)) {
            return SINK_FORMAT_SUPPORTED_WITH_TRANSCODING;
        }
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
        toInt16.reset();
        convertToInt16 = false;
        floatFormat = null;
        highResolutionInput = floatOutput && MimeTypes.AUDIO_RAW.equals(format.sampleMimeType)
                && Util.isEncodingHighResolutionPcm(format.pcmEncoding);
        if (highResolutionInput && (compatibleProcessingRequired || !acceptsFloat.test(format)
                || outputChannels != null || format.encoderDelay > 0 || format.encoderPadding > 0)) {
            configureInt16(format, specifiedBufferSize, outputChannels);
            return;
        }
        super.configure(format, specifiedBufferSize, outputChannels);
        if (!highResolutionInput) {
            applyCompatiblePlaybackProcessing();
            return;
        }
        floatFormat = format;
        bufferSize = specifiedBufferSize;
        this.outputChannels = outputChannels;
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

    private void configureInt16(Format format, int specifiedBufferSize, @Nullable int[] channels)
            throws AudioSink.ConfigurationException {
        try {
            toInt16.configure(new AudioProcessor.AudioFormat(
                    format.sampleRate, format.channelCount, format.pcmEncoding));
            toInt16.flush();
            super.configure(format.buildUpon().setPcmEncoding(C.ENCODING_PCM_16BIT).build(),
                    specifiedBufferSize, channels);
            convertToInt16 = true;
            applyCompatiblePlaybackProcessing();
        } catch (AudioProcessor.UnhandledAudioFormatException error) {
            throw new AudioSink.ConfigurationException(error, format);
        }
    }

    private void applyCompatiblePlaybackProcessing() {
        // Media3 may clear its effective settings while stopping the float
        // route. Apply the user's requested values to the new PCM16 chain.
        super.setSkipSilenceEnabled(skipSilenceRequested);
        super.setPlaybackParameters(requestedPlaybackParameters);
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
        pendingInputPosition = input.position();
        pendingOutput = input;
        if (convertToInt16) {
            toInt16.queueInput(input);
            pendingOutput = toInt16.getOutput();
        } else if (highResolutionDsp && !processor.isBypassed()) {
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
        try {
            if (!super.handleBuffer(pendingOutput, pendingPresentationTimeUs, pendingAccessUnitCount)) {
                return false;
            }
        } catch (AudioSink.InitializationException error) {
            // Retry the first buffer through the compatible chain if Android
            // rejects float when opening the audio device.
            Format rejected = floatFormat;
            if (rejected == null) throw error;
            ByteBuffer input = pendingInput;
            int position = pendingInputPosition;
            long presentationTimeUs = pendingPresentationTimeUs;
            int encodedAccessUnitCount = pendingAccessUnitCount;
            floatFormat = null;
            flush();
            configuration.beginRoute();
            highResolutionDsp = false;
            processor.reset();
            try {
                configureInt16(rejected, bufferSize, outputChannels);
            } catch (AudioSink.ConfigurationException fallbackError) {
                error.addSuppressed(fallbackError);
                throw error;
            }
            input.position(position);
            return handleBuffer(input, presentationTimeUs, encodedAccessUnitCount);
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
        toInt16.flush();
        super.flush();
    }

    @Override
    public void reset() {
        clearPending();
        highResolutionDsp = false;
        highResolutionInput = false;
        floatFormat = null;
        convertToInt16 = false;
        toInt16.reset();
        processor.reset();
        super.reset();
    }

    @Override
    public void release() {
        clearPending();
        highResolutionDsp = false;
        highResolutionInput = false;
        floatFormat = null;
        convertToInt16 = false;
        toInt16.reset();
        processor.reset();
        super.release();
    }

    private void clearPending() {
        pendingInput = null;
        pendingOutput = null;
    }
}
