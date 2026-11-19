package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/** Ten independent native peaking biquads; no Android AudioEffect or Dart PCM. */
final class BStreamEqualizerAudioProcessor extends BaseAudioProcessor {
    private static final int BANDS = BStreamEqualizerConfiguration.FREQUENCIES.length;
    private static final int COEFFICIENTS = 5;
    // Direct iteration is cheaper than sparse indexing for mostly full curves.
    private static final int MIN_DENSE_BANDS = 7;
    private static final double Q = 1;
    private static final double TRANSITION_SECONDS = 0.025;
    private final BStreamEqualizerConfiguration configuration;
    private final double[] coefficients = new double[BANDS * COEFFICIENTS];
    private final double[] target = new double[BANDS * COEFFICIENTS];
    private final double[] coefficientStep = new double[BANDS * COEFFICIENTS];
    private final int[] processingBands = new int[BANDS];
    private double[] z1 = new double[0];
    private double[] z2 = new double[0];
    private long revision = -1;
    private int transitionFrames;
    private double preamp = 1;
    private double targetPreamp = 1;
    private double preampStep;
    private boolean bypass = true;
    private boolean targetBypass = true;
    private boolean denseTarget;
    private ByteBuffer pendingFrame = EMPTY_BUFFER;
    private int pendingBytes;
    private long pendingRouteGeneration;
    private long activeRouteGeneration;

    BStreamEqualizerAudioProcessor(BStreamEqualizerConfiguration configuration) {
        this.configuration = configuration;
        identity(coefficients);
        identity(target);
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat format) throws UnhandledAudioFormatException {
        if (format.sampleRate <= 0 || format.channelCount <= 0 ||
                (format.encoding != C.ENCODING_PCM_16BIT &&
                 format.encoding != C.ENCODING_PCM_16BIT_BIG_ENDIAN &&
                 format.encoding != C.ENCODING_PCM_FLOAT &&
                 format.encoding != C.ENCODING_PCM_24BIT &&
                 format.encoding != C.ENCODING_PCM_24BIT_BIG_ENDIAN &&
                 format.encoding != C.ENCODING_PCM_32BIT &&
                 format.encoding != C.ENCODING_PCM_32BIT_BIG_ENDIAN)) {
            throw new UnhandledAudioFormatException(format);
        }
        // Stay in the processing chain so enabling during playback needs no
        // decoder restart. Flat/off use one buffer copy and no sample DSP.
        pendingRouteGeneration = configuration.routeGeneration();
        return format;
    }

    @Override
    protected void onFlush() {
        if (inputAudioFormat == AudioFormat.NOT_SET) return;
        z1 = new double[BANDS * inputAudioFormat.channelCount];
        z2 = new double[z1.length];
        pendingFrame = ByteBuffer.allocate(inputAudioFormat.bytesPerFrame).order(byteOrder());
        pendingBytes = 0;
        revision = -1;
        transitionFrames = 0;
        bypass = true;
        denseTarget = false;
        targetBypass = true;
        preamp = targetPreamp = 1;
        identity(coefficients);
        activeRouteGeneration = pendingRouteGeneration;
        configuration.configured(this, activeRouteGeneration, inputAudioFormat.sampleRate,
                inputAudioFormat.channelCount, inputAudioFormat.encoding);
        updateConfiguration(true);
    }

    @Override
    protected void onReset() {
        configuration.unconfigured(this, activeRouteGeneration);
        activeRouteGeneration = pendingRouteGeneration = -1;
        z1 = z2 = new double[0];
        pendingFrame = EMPTY_BUFFER;
        pendingBytes = 0;
        revision = -1;
        bypass = true;
    }

    boolean isBypassed() {
        return bypass && !configuration.isActive();
    }

    private static void identity(double[] values) {
        Arrays.fill(values, 0);
        for (int band = 0; band < BANDS; band++) values[band * COEFFICIENTS] = 1;
    }

    private void updateConfiguration(boolean immediate) {
        BStreamEqualizerConfiguration.Snapshot settings = configuration.snapshot();
        if (revision == settings.revision) return;
        revision = settings.revision;
        targetBypass = !settings.active();
        targetPreamp = targetBypass ? 1 : Math.pow(10, settings.preampDb / 20);
        int nonNeutralBands = 0;
        for (int band = 0; band < BANDS; band++) {
            int offset = band * COEFFICIENTS;
            double gain = targetBypass ? 0 : settings.gainsDb[band];
            double frequency = BStreamEqualizerConfiguration.FREQUENCIES[band];
            // An unavailable high band must not be remapped into audible lower
            // frequencies. Keep the shared curve's conservative preamp only.
            if (frequency >= inputAudioFormat.sampleRate * 0.5 || Math.abs(gain) < 0.01) {
                target[offset] = 1;
                for (int i = 1; i < COEFFICIENTS; i++) target[offset + i] = 0;
                continue;
            }
            nonNeutralBands++;
            double amplitude = Math.pow(10, gain / 40);
            double omega = 2 * Math.PI * frequency / inputAudioFormat.sampleRate;
            double alpha = Math.sin(omega) / (2 * Q);
            double cosine = Math.cos(omega);
            double a0 = 1 + alpha / amplitude;
            target[offset] = (1 + alpha * amplitude) / a0;
            target[offset + 1] = -2 * cosine / a0;
            target[offset + 2] = (1 - alpha * amplitude) / a0;
            target[offset + 3] = -2 * cosine / a0;
            target[offset + 4] = (1 - alpha / amplitude) / a0;
        }
        denseTarget = nonNeutralBands >= MIN_DENSE_BANDS;
        if (immediate) {
            System.arraycopy(target, 0, coefficients, 0, target.length);
            preamp = targetPreamp;
            bypass = targetBypass;
            transitionFrames = 0;
        } else {
            transitionFrames = Math.max(1, (int)(inputAudioFormat.sampleRate * TRANSITION_SECONDS));
            for (int i = 0; i < target.length; i++) {
                coefficientStep[i] = (target[i] - coefficients[i]) / transitionFrames;
            }
            preampStep = (targetPreamp - preamp) / transitionFrames;
            bypass = false;
        }
    }

    @Override
    public void queueInput(ByteBuffer input) {
        if (!input.hasRemaining()) return;
        configuration.ensureConfigured(this, activeRouteGeneration, inputAudioFormat.sampleRate,
                inputAudioFormat.channelCount, inputAudioFormat.encoding);
        updateConfiguration(false);
        int bytesPerFrame = inputAudioFormat.bytesPerFrame;
        int frames = (pendingBytes + input.remaining()) / bytesPerFrame;
        ByteBuffer output = replaceOutputBuffer(frames * bytesPerFrame).order(byteOrder());
        input.order(byteOrder());
        if (pendingBytes > 0) {
            int take = Math.min(input.remaining(), bytesPerFrame - pendingBytes);
            input.get(pendingFrame.array(), pendingBytes, take);
            pendingBytes += take;
            if (pendingBytes == bytesPerFrame) {
                pendingFrame.position(0);
                pendingFrame.limit(bytesPerFrame);
                processFrames(pendingFrame, 1, output);
                pendingBytes = 0;
            }
        }
        int completeFrames = input.remaining() / bytesPerFrame;
        processFrames(input, completeFrames, output);
        if (input.hasRemaining()) {
            pendingBytes = input.remaining();
            input.get(pendingFrame.array(), 0, pendingBytes);
        }
        output.flip();
        configuration.processed(frames, transitionFrames == 0 ? revision : -1, activeRouteGeneration);
    }

    private ByteOrder byteOrder() {
        int encoding = inputAudioFormat.encoding;
        return encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN ||
                encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN ||
                encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN
                ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN;
    }

    private void copyFrames(ByteBuffer input, int frames, ByteBuffer output) {
        int originalLimit = input.limit();
        input.limit(input.position() + frames * inputAudioFormat.bytesPerFrame);
        output.put(input);
        input.limit(originalLimit);
    }

    private void processFrames(ByteBuffer input, int frames, ByteBuffer output) {
        if (frames == 0) return;
        if (bypass) {
            copyFrames(input, frames, output);
            return;
        }
        if (transitionFrames > 0 || denseTarget) {
            processFramesDense(input, frames, output);
            return;
        }
        // Scan only sparse targets. Full curves retain the original constant
        // ten-band kernel, dispatched once per block rather than per sample.
        int count = selectProcessingBands();
        if (count >= MIN_DENSE_BANDS) processFramesDense(input, frames, output);
        else processFramesSparse(input, frames, output, count);
    }

    // Intentionally retain this original dense loop separately: a mutable
    // sparse/dense condition inside the sample loop regresses ART throughput.
    // Configuration, PCM conversion and filter state are shared by both paths.
    private void processFramesDense(ByteBuffer input, int frames, ByteBuffer output) {
        if (bypass) {
            copyFrames(input, frames, output);
        } else {
            for (int frame = 0; frame < frames; frame++) {
                if (transitionFrames > 0) {
                    for (int i = 0; i < coefficients.length; i++) coefficients[i] += coefficientStep[i];
                    preamp += preampStep;
                    if (--transitionFrames == 0) {
                        System.arraycopy(target, 0, coefficients, 0, target.length);
                        preamp = targetPreamp;
                        bypass = targetBypass;
                        if (bypass) { Arrays.fill(z1, 0); Arrays.fill(z2, 0); }
                    }
                }
                if (bypass) {
                    copyFrames(input, frames - frame, output);
                    break;
                }
                for (int channel = 0; channel < inputAudioFormat.channelCount; channel++) {
                    double sample = readSample(input, inputAudioFormat.encoding);
                    if (!Double.isFinite(sample)) sample = 0;
                    sample *= preamp;
                    if (!bypass) {
                        for (int band = 0; band < BANDS; band++) {
                            int state = band * inputAudioFormat.channelCount + channel;
                            int c = band * COEFFICIENTS;
                            double filtered = coefficients[c] * sample + z1[state];
                            z1[state] = coefficients[c + 1] * sample - coefficients[c + 3] * filtered + z2[state];
                            z2[state] = coefficients[c + 2] * sample - coefficients[c + 4] * filtered;
                            sample = filtered;
                        }
                    }
                    writeSample(output, inputAudioFormat.encoding, sample);
                }
            }
        }
    }

    private void processFramesSparse(ByteBuffer input, int frames, ByteBuffer output, int processingBandCount) {
        for (int frame = 0; frame < frames; frame++) {
            for (int channel = 0; channel < inputAudioFormat.channelCount; channel++) {
                double sample = readSample(input, inputAudioFormat.encoding);
                if (!Double.isFinite(sample)) sample = 0;
                sample *= preamp;
                if (processingBandCount == BANDS) {
                    sample = filterRemaining(sample, 0, channel);
                } else {
                    int previousBand = -1;
                    for (int index = 0; index < processingBandCount; index++) {
                        int band = processingBands[index];
                        if (sample == 0 && Double.doubleToRawLongBits(sample) != 0 && band > previousBand + 1) {
                            // A negative zero can change a neutral filter's
                            // signed-zero history. Preserve the exact dense
                            // recurrence for this channel and remaining block.
                            sample = filterRemaining(sample, previousBand + 1, channel);
                            processingBandCount = BANDS;
                            previousBand = BANDS - 1;
                            break;
                        }
                        int state = band * inputAudioFormat.channelCount + channel;
                        int c = band * COEFFICIENTS;
                        double filtered = coefficients[c] * sample + z1[state];
                        z1[state] = coefficients[c + 1] * sample - coefficients[c + 3] * filtered + z2[state];
                        z2[state] = coefficients[c + 2] * sample - coefficients[c + 4] * filtered;
                        sample = filtered;
                        previousBand = band;
                    }
                    if (sample == 0 && Double.doubleToRawLongBits(sample) != 0 && previousBand < BANDS - 1) {
                        sample = filterRemaining(sample, previousBand + 1, channel);
                        processingBandCount = BANDS;
                    }
                }
                writeSample(output, inputAudioFormat.encoding, sample);
            }
        }
    }

    private int selectProcessingBands() {
        int count = 0;
        for (int band = 0; band < BANDS; band++) {
            int c = band * COEFFICIENTS;
            boolean identity = coefficients[c] == 1;
            for (int index = 1; identity && index < COEFFICIENTS; index++) {
                identity = Double.doubleToRawLongBits(coefficients[c + index]) == 0;
            }
            for (int channel = 0; identity && channel < inputAudioFormat.channelCount; channel++) {
                int state = band * inputAudioFormat.channelCount + channel;
                identity = Double.doubleToRawLongBits(z1[state]) == 0 &&
                        Double.doubleToRawLongBits(z2[state]) == 0;
            }
            if (!identity) processingBands[count++] = band;
        }
        return count;
    }

    private double filterRemaining(double sample, int startBand, int channel) {
        for (int band = startBand; band < BANDS; band++) {
            int state = band * inputAudioFormat.channelCount + channel;
            int c = band * COEFFICIENTS;
            double filtered = coefficients[c] * sample + z1[state];
            z1[state] = coefficients[c + 1] * sample - coefficients[c + 3] * filtered + z2[state];
            z2[state] = coefficients[c + 2] * sample - coefficients[c + 4] * filtered;
            sample = filtered;
        }
        return sample;
    }

    private static double readSample(ByteBuffer input, int encoding) {
        if (encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN) {
            return input.getShort() / 32768.0;
        }
        if (encoding == C.ENCODING_PCM_FLOAT) return input.getFloat();
        if (encoding == C.ENCODING_PCM_32BIT || encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN) {
            return input.getInt() / 2147483648.0;
        }
        int value = encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN
                ? (input.get() << 16) | ((input.get() & 255) << 8) | (input.get() & 255)
                : (input.get() & 255) | ((input.get() & 255) << 8) | (input.get() << 16);
        return value / 8388608.0;
    }

    private static void writeSample(ByteBuffer output, int encoding, double sample) {
        if (!Double.isFinite(sample)) sample = 0;
        sample = Math.max(-1, Math.min(1, sample));
        if (encoding == C.ENCODING_PCM_FLOAT) {
            output.putFloat((float)sample);
        } else if (encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN) {
            output.putShort((short)Math.max(-32768, Math.min(32767, Math.round(sample * 32768))));
        } else if (encoding == C.ENCODING_PCM_32BIT || encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN) {
            output.putInt((int)Math.max(Integer.MIN_VALUE, Math.min(Integer.MAX_VALUE, Math.round(sample * 2147483648.0))));
        } else {
            int value = (int)Math.max(-8388608, Math.min(8388607, Math.round(sample * 8388608)));
            if (encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN) {
                output.put((byte)(value >> 16));
                output.put((byte)(value >> 8));
                output.put((byte)value);
            } else {
                output.put((byte)value);
                output.put((byte)(value >> 8));
                output.put((byte)(value >> 16));
            }
        }
    }
}
