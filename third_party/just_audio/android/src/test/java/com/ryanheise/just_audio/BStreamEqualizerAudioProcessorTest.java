package com.ryanheise.just_audio;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import java.util.Random;
import org.junit.Test;

/** Tests decoded samples, independently of status readback or coefficient formulas. */
public final class BStreamEqualizerAudioProcessorTest {
    private static final double[] CENTERS = {60, 230, 910, 3600, 14000};
    private static final int[] ENCODINGS = {
        C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT,
        C.ENCODING_PCM_24BIT, C.ENCODING_PCM_32BIT,
        C.ENCODING_PCM_16BIT_BIG_ENDIAN, C.ENCODING_PCM_24BIT_BIG_ENDIAN,
        C.ENCODING_PCM_32BIT_BIG_ENDIAN
    };
    private static final int[] FRAME_CHUNKS = {1, 37, 257, 1024, 173};

    @Test
    public void isolatedSixDbCutsAttenuateEveryBandAtItsCenter() throws Exception {
        // Measuring each center with a single cut avoids reproducing the
        // implementation's biquad equations or depending on boost headroom.
        for (int sampleRate : new int[] {44100, 48000}) {
            for (int encoding : ENCODINGS) {
                for (int band = 0; band < CENTERS.length; band++) {
                    double[] gains = new double[5];
                    gains[band] = -6;
                    BStreamEqualizerConfiguration state = state(true, gains);
                    BStreamEqualizerAudioProcessor processor = processor(
                        state, sampleRate, 1, encoding);
                    try {
                        byte[] input = tone(sampleRate, 1, encoding, 0,
                            CENTERS[band], .2, sampleRate * 3 / 4, 0);
                        byte[] output = queue(processor, input,
                            frameChunks(encoding, 1), true);
                        assertEquals(input.length, output.length);
                        double gain = measuredGainDb(input, output, encoding,
                            1, 0, sampleRate, CENTERS[band], sampleRate / 4);
                        assertEquals("center " + CENTERS[band] + " / " + encoding,
                            -6, gain, .04);
                        assertEquals(0, state.snapshot().preampDb, 0);
                        assertEquals(sampleRate * 3 / 4, state.processedFrames());
                    } finally {
                        processor.reset();
                    }
                }
            }
        }
    }

    @Test
    public void boostHeadroomIsAppliedBeforePcmQuantization() throws Exception {
        for (int encoding : ENCODINGS) {
            BStreamEqualizerConfiguration state = state(true, new double[] {0, 0, 6, 0, 0});
            BStreamEqualizerAudioProcessor processor = processor(state, 48000, 1, encoding);
            try {
                // A +6 dB filter without its -6 dB input margin would clip this
                // 0.8-amplitude signal before the player's master-volume stage.
                byte[] input = tone(48000, 1, encoding, 0, 910, .8, 36000, 0);
                byte[] output = queue(processor, input, frameChunks(encoding, 1), true);
                assertEquals(0, measuredGainDb(input, output, encoding,
                    1, 0, 48000, 910, 12000), .04);
                assertTrue("headroom must avoid clipped peaks", maxAbs(output, encoding) < .85);
                assertEquals(-6, state.snapshot().preampDb, 0);
            } finally {
                processor.reset();
            }
        }
    }

    @Test
    public void bandsAboveNyquistDoNotRetuneOrAliasIntoLowRateAudio() throws Exception {
        for (int rate : new int[] {8000, 16000, 22050}) {
            for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                for (double gain : new double[] {-6, 6}) {
                    BStreamEqualizerAudioProcessor processor = processor(
                        state(true, new double[] {0, 0, 0, 0, gain}), rate, 1, encoding);
                    try {
                        byte[] input = tone(rate, 1, encoding, 0, 1000, .4, rate / 2, 0);
                        byte[] output = queue(processor, input, frameChunks(encoding, 1), true);
                        if (gain < 0) {
                            // 14 kHz cannot exist in these sources. Its cut must
                            // not move to a lower, audible center frequency.
                            assertArrayEquals(input, output);
                        } else {
                            // The declared boost still reserves its global
                            // headroom, but contributes no out-of-range filter.
                            assertEquals(-6, measuredGainDb(input, output, encoding,
                                1, 0, rate, 1000, 0), .04);
                            assertTrue(maxAbs(output, encoding) < .21);
                        }
                    } finally {
                        processor.reset();
                    }
                }
            }
        }
    }

    @Test
    public void bypassPreservesEveryByteForEveryPcmEncoding() throws Exception {
        for (int encoding : ENCODINGS) {
            for (boolean enabled : new boolean[] {false, true}) {
                double[] gains = enabled ? new double[5] : new double[] {6, -3, 2, 4, -5};
                BStreamEqualizerConfiguration state = state(enabled, gains);
                BStreamEqualizerAudioProcessor processor = processor(state, 48000, 2, encoding);
                try {
                    byte[] input = new byte[513 * 2 * bytesPerSample(encoding)];
                    // Include arbitrary float payloads and signed zero: bypass
                    // must copy their representation, not decode/re-encode it.
                    new Random(7023).nextBytes(input);
                    byte[] output = queue(processor, input, frameChunks(encoding, 2), true);
                    assertArrayEquals(input, output);
                    assertTrue(processor.isBypassed());
                    assertTrue("remain in Media3 chain for live enabling", processor.isActive());
                } finally {
                    processor.reset();
                }
            }
        }
    }

    @Test
    public void splitBuffersCannotDropFramesOrChangeFilterHistory() throws Exception {
        for (int encoding : ENCODINGS) {
            for (boolean active : new boolean[] {false, true}) {
                double[] gains = {-3.5, 0, -6, 1.5, -2};
                BStreamEqualizerAudioProcessor reference = processor(
                    state(active, gains), 48000, 2, encoding);
                BStreamEqualizerConfiguration fragmentedState = state(active, gains);
                BStreamEqualizerAudioProcessor fragmented = processor(
                    fragmentedState, 48000, 2, encoding);
                try {
                    byte[] input = tone(48000, 2, encoding, 1, 910, .2, 4099, 0);
                    byte[] expected = queue(reference, input, new int[] {input.length}, true);
                    // These boundaries intentionally split both samples and
                    // interleaved frames, including 24-bit and stereo PCM.
                    byte[] actual = queue(fragmented, input,
                        new int[] {1, 3, 7, 131, 1024, 5}, true);
                    assertArrayEquals("fragmented encoding " + encoding, expected, actual);
                    assertEquals(input.length, actual.length);
                    assertEquals(4099, fragmentedState.processedFrames());
                } finally {
                    reference.reset();
                    fragmented.reset();
                }
            }
        }
    }

    @Test
    public void interleavedChannelsHaveIndependentFilterState() throws Exception {
        for (int channels : new int[] {2, 6}) {
            for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                BStreamEqualizerAudioProcessor processor = processor(
                    state(true, new double[] {0, -6, 0, 0, 0}), 48000, channels, encoding);
                try {
                    int selected = channels - 1;
                    byte[] input = tone(48000, channels, encoding, selected, 230, .3, 36000, 0);
                    byte[] output = queue(processor, input, frameChunks(encoding, channels), true);
                    assertEquals(-6, measuredGainDb(input, output, encoding,
                        channels, selected, 48000, 230, 12000), .04);
                    double[] decoded = decode(output, encoding);
                    for (int sample = 0; sample < decoded.length; sample++) {
                        if (sample % channels != selected) {
                            assertEquals("silent channel received another channel's history",
                                0, decoded[sample], 0);
                        }
                    }
                } finally {
                    processor.reset();
                }
            }
        }
    }

    @Test
    public void seekFlushClearsRingingAndFormatResetStartsFresh() throws Exception {
        BStreamEqualizerConfiguration state = state(true, new double[] {-12, 0, 0, 0, 0});
        BStreamEqualizerAudioProcessor processor = processor(state, 48000, 1, C.ENCODING_PCM_16BIT);
        try {
            byte[] impulse = new byte[200];
            ByteBuffer.wrap(impulse).order(ByteOrder.LITTLE_ENDIAN).putShort((short)16000);
            queue(processor, impulse, new int[] {impulse.length}, false);
            processor.flush();
            byte[] silence = new byte[4096 * 2];
            assertArrayEquals(silence,
                queue(processor, silence, frameChunks(C.ENCODING_PCM_16BIT, 1), false));

            processor.reset();
            state.configure(true, new double[] {0, 0, -6, 0, 0});
            processor.configure(new AudioProcessor.AudioFormat(44100, 2, C.ENCODING_PCM_FLOAT));
            processor.flush();
            byte[] input = tone(44100, 2, C.ENCODING_PCM_FLOAT,
                1, 910, .2, 33075, 0);
            byte[] output = queue(processor, input,
                frameChunks(C.ENCODING_PCM_FLOAT, 2), true);
            assertEquals(input.length, output.length);
            assertEquals(-6, measuredGainDb(input, output, C.ENCODING_PCM_FLOAT,
                2, 1, 44100, 910, 11025), .04);
            assertEquals(44100, state.sampleRate());
            assertEquals(2, state.channelCount());
            assertEquals(C.ENCODING_PCM_FLOAT, state.encoding());
        } finally {
            processor.reset();
        }
    }

    @Test
    public void liveChangesGlideThenReturnToBitExactBypass() throws Exception {
        for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
            BStreamEqualizerConfiguration state = state(false, new double[5]);
            BStreamEqualizerAudioProcessor processor = processor(state, 48000, 1, encoding);
            try {
                byte[] warm = tone(48000, 1, encoding, 0, 910, .3, 4800, 0);
                assertArrayEquals(warm, queue(processor, warm, frameChunks(encoding, 1), false));
                state.configure(true, new double[] {0, 0, -12, 0, 0});
                byte[] transition = tone(48000, 1, encoding, 0, 910, .3, 12000, 4800);
                byte[] output = queue(processor, transition, frameChunks(encoding, 1), false);
                double[] inputSamples = decode(transition, encoding);
                double[] outputSamples = decode(output, encoding);
                // tone() starts at a peak here. An immediate coefficient jump
                // would change this sample by much more than the gradual ramp.
                assertEquals(inputSamples[0], outputSamples[0], .001);
                assertEquals(-12, measuredGainDb(transition, output, encoding,
                    1, 0, 48000, 910, 7200), .05);

                state.configure(false, new double[] {0, 0, -12, 0, 0});
                byte[] returning = tone(48000, 1, encoding, 0, 910, .3, 4800, 16800);
                byte[] bypassed = queue(processor, returning, frameChunks(encoding, 1), false);
                int settledOffset = 2400 * bytesPerSample(encoding);
                assertArrayEquals(Arrays.copyOfRange(returning, settledOffset, returning.length),
                    Arrays.copyOfRange(bypassed, settledOffset, bypassed.length));
                assertTrue(processor.isBypassed());
                assertArrayEquals(returning,
                    queue(processor, returning, frameChunks(encoding, 1), true));
            } finally {
                processor.reset();
            }
        }
    }

    @Test
    public void extremeCurvesAndRapidUpdatesKeepBoundedSignalsFinite() throws Exception {
        BStreamEqualizerConfiguration state = state(true, new double[] {12, 12, 12, 12, 12});
        BStreamEqualizerAudioProcessor processor = processor(state, 48000, 2, C.ENCODING_PCM_FLOAT);
        try {
            for (int block = 0; block < 160; block++) {
                if (block % 2 == 0) {
                    state.configure(true, new double[] {-12, 12, -12, 12, -12});
                } else {
                    state.configure(true, new double[] {12, -12, 12, -12, 12});
                }
                byte[] input = tone(48000, 2, C.ENCODING_PCM_FLOAT,
                    block % 2, CENTERS[block % 5], .05, 257, block * 257);
                byte[] output = queue(processor, input, new int[] {input.length}, false);
                assertEquals(input.length, output.length);
                assertTrue("bounded input must not reach PCM clipping rails",
                    maxAbs(output, C.ENCODING_PCM_FLOAT) < .95);
            }
            // Non-finite decoder samples must not poison persistent IIR state.
            ByteBuffer invalid = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN);
            invalid.putFloat(Float.NaN).putFloat(Float.POSITIVE_INFINITY)
                .putFloat(Float.NEGATIVE_INFINITY).putFloat(.01f);
            byte[] output = queue(processor, invalid.array(), new int[] {16}, false);
            maxAbs(output, C.ENCODING_PCM_FLOAT); // also checks every sample is finite
        } finally {
            processor.reset();
        }
    }

    @Test
    public void outputStorageIsReusedForEqualSizedAudioBlocks() throws Exception {
        BStreamEqualizerAudioProcessor processor = processor(
            state(true, new double[] {0, 0, -6, 0, 0}), 48000, 1, C.ENCODING_PCM_FLOAT);
        try {
            byte[] input = tone(48000, 1, C.ENCODING_PCM_FLOAT, 0, 910, .2, 257, 0);
            processor.queueInput(buffer(input, 0, input.length));
            ByteBuffer first = processor.getOutput();
            assertEquals(input.length, first.remaining());
            first.position(first.limit());
            processor.queueInput(buffer(input, 0, input.length));
            ByteBuffer second = processor.getOutput();
            assertSame("audio callbacks should reuse an already large enough buffer", first, second);
            assertEquals(input.length, second.remaining());
            second.position(second.limit());
        } finally {
            processor.reset();
        }
    }

    private static BStreamEqualizerConfiguration state(boolean enabled, double[] gains) {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(enabled, gains);
        return state;
    }

    private static BStreamEqualizerAudioProcessor processor(
            BStreamEqualizerConfiguration state, int rate, int channels, int encoding)
            throws Exception {
        BStreamEqualizerAudioProcessor processor = new BStreamEqualizerAudioProcessor(state);
        AudioProcessor.AudioFormat output = processor.configure(
            new AudioProcessor.AudioFormat(rate, channels, encoding));
        assertEquals(rate, output.sampleRate);
        assertEquals(channels, output.channelCount);
        assertEquals(encoding, output.encoding);
        processor.flush();
        return processor;
    }

    private static int[] frameChunks(int encoding, int channels) {
        int bytesPerFrame = bytesPerSample(encoding) * channels;
        return Arrays.stream(FRAME_CHUNKS).map(frames -> frames * bytesPerFrame).toArray();
    }

    private static byte[] queue(BStreamEqualizerAudioProcessor processor, byte[] input,
            int[] chunks, boolean end) {
        ByteArrayOutputStream output = new ByteArrayOutputStream(input.length);
        int offset = 0;
        int chunk = 0;
        while (offset < input.length) {
            int bytes = Math.min(chunks[chunk++ % chunks.length], input.length - offset);
            ByteBuffer buffer = buffer(input, offset, bytes);
            processor.queueInput(buffer);
            assertTrue("queueInput must consume even a partial interleaved frame", !buffer.hasRemaining());
            drain(processor, output);
            offset += bytes;
        }
        if (end) {
            processor.queueEndOfStream();
            drain(processor, output);
            assertTrue(processor.isEnded());
        }
        return output.toByteArray();
    }

    private static ByteBuffer buffer(byte[] bytes, int offset, int length) {
        // Nonzero positions/limits catch accidental reads of a buffer's prefix.
        ByteBuffer buffer = ByteBuffer.allocateDirect(length + 6).order(ByteOrder.LITTLE_ENDIAN);
        buffer.position(3);
        buffer.put(bytes, offset, length);
        buffer.limit(buffer.position());
        buffer.position(3);
        return buffer;
    }

    private static void drain(BStreamEqualizerAudioProcessor processor, ByteArrayOutputStream output) {
        ByteBuffer buffer = processor.getOutput();
        byte[] bytes = new byte[buffer.remaining()];
        buffer.get(bytes);
        output.write(bytes, 0, bytes.length);
    }

    private static byte[] tone(int rate, int channels, int encoding, int selectedChannel,
            double frequency, double amplitude, int frames, int initialFrame) {
        ByteBuffer output = ByteBuffer.allocate(frames * channels * bytesPerSample(encoding))
            .order(isBigEndian(encoding) ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN);
        for (int frame = 0; frame < frames; frame++) {
            double sample = amplitude * Math.cos(2 * Math.PI * frequency * (frame + initialFrame) / rate);
            for (int channel = 0; channel < channels; channel++) {
                encode(output, encoding, channel == selectedChannel ? sample : 0);
            }
        }
        return output.array();
    }

    private static int bytesPerSample(int encoding) {
        if (encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN) return 2;
        if (encoding == C.ENCODING_PCM_24BIT || encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN) return 3;
        return 4;
    }

    private static boolean isBigEndian(int encoding) {
        return encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN ||
            encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN ||
            encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN;
    }

    private static void encode(ByteBuffer output, int encoding, double sample) {
        if (encoding == C.ENCODING_PCM_FLOAT) {
            output.putFloat((float)sample);
        } else if (encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN) {
            output.putShort((short)Math.round(sample * 32767));
        } else if (encoding == C.ENCODING_PCM_32BIT || encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN) {
            output.putInt((int)Math.round(sample * Integer.MAX_VALUE));
        } else {
            int value = (int)Math.round(sample * 8388607);
            if (isBigEndian(encoding)) {
                output.put((byte)(value >> 16)).put((byte)(value >> 8)).put((byte)value);
            } else {
                output.put((byte)value).put((byte)(value >> 8)).put((byte)(value >> 16));
            }
        }
    }

    private static double[] decode(byte[] bytes, int encoding) {
        ByteBuffer input = ByteBuffer.wrap(bytes)
            .order(isBigEndian(encoding) ? ByteOrder.BIG_ENDIAN : ByteOrder.LITTLE_ENDIAN);
        double[] values = new double[bytes.length / bytesPerSample(encoding)];
        for (int sample = 0; sample < values.length; sample++) {
            if (encoding == C.ENCODING_PCM_FLOAT) values[sample] = input.getFloat();
            else if (encoding == C.ENCODING_PCM_16BIT || encoding == C.ENCODING_PCM_16BIT_BIG_ENDIAN) {
                values[sample] = input.getShort() / 32768.0;
            } else if (encoding == C.ENCODING_PCM_32BIT || encoding == C.ENCODING_PCM_32BIT_BIG_ENDIAN) {
                values[sample] = input.getInt() / 2147483648.0;
            }
            else {
                int value;
                if (isBigEndian(encoding)) {
                    value = (input.get() << 16) | ((input.get() & 255) << 8) | (input.get() & 255);
                } else {
                    value = (input.get() & 255) | ((input.get() & 255) << 8) | (input.get() << 16);
                }
                values[sample] = value / 8388608.0;
            }
        }
        return values;
    }

    private static double measuredGainDb(byte[] input, byte[] output, int encoding,
            int channels, int selectedChannel, int rate, double frequency, int skipFrames) {
        double before = amplitude(decode(input, encoding), channels, selectedChannel,
            rate, frequency, skipFrames);
        double after = amplitude(decode(output, encoding), channels, selectedChannel,
            rate, frequency, skipFrames);
        assertTrue(before > 0);
        assertTrue(after > 0);
        return 20 * Math.log10(after / before);
    }

    private static double amplitude(double[] samples, int channels, int selectedChannel,
            int rate, double frequency, int skipFrames) {
        double real = 0;
        double imaginary = 0;
        int frames = samples.length / channels;
        for (int frame = skipFrames; frame < frames; frame++) {
            double sample = samples[frame * channels + selectedChannel];
            assertTrue("non-finite PCM sample", Double.isFinite(sample));
            double angle = 2 * Math.PI * frequency * frame / rate;
            real += sample * Math.cos(angle);
            imaginary += sample * Math.sin(angle);
        }
        return 2 * Math.hypot(real, imaginary) / (frames - skipFrames);
    }

    private static double maxAbs(byte[] bytes, int encoding) {
        double maximum = 0;
        for (double sample : decode(bytes, encoding)) {
            assertTrue("non-finite PCM output", Double.isFinite(sample));
            maximum = Math.max(maximum, Math.abs(sample));
        }
        return maximum;
    }
}
