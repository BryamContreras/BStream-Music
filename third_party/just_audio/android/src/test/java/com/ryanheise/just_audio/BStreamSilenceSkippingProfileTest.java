package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;

public final class BStreamSilenceSkippingProfileTest {
    private static final int SAMPLE_RATE = 16_000;

    @Test
    public void profileProtectsFourSecondMusicalPauses() throws Exception {
        short[] samples = concat(
            tone(250, 2_800),
            silence(4_000),
            tone(250, 2_800));

        assertEquals(samples.length, process(samples));
        assertEquals(samples.length, process(samples, 2));
        assertEquals(samples.length, process(samples, 6));
    }

    @Test
    public void profileProtectsVeryQuietInstrumentation() throws Exception {
        // Peak 80 is approximately -52 dBFS and remains above BStream's
        // deliberately conservative detector threshold.
        short[] samples = concat(
            tone(250, 2_800),
            tone(6_000, 80),
            tone(250, 2_800));

        assertEquals(samples.length, process(samples));
    }

    @Test
    public void profileProtectsAReverbTail() throws Exception {
        short[] samples = concat(
            tone(250, 2_800),
            decayingTone(4_000, 4_096, 16),
            tone(250, 2_800));

        assertEquals(samples.length, process(samples));
    }

    @Test
    public void profileShortensOnlyTheExcessOfALongEmptyGap() throws Exception {
        short[] samples = concat(
            tone(250, 2_800),
            silence(10_000),
            tone(250, 2_800));

        for (int channelCount : new int[] {1, 2, 6}) {
            long outputFrames = process(samples, channelCount);
            long retainedGapFrames = outputFrames - frames(500);

            assertTrue(
                "a natural margin must remain for " + channelCount
                    + " channels; retained frames=" + retainedGapFrames,
                retainedGapFrames >= frames(5_700));
            assertTrue(
                "a genuinely long gap must still be shortened for " + channelCount
                    + " channels; retained frames=" + retainedGapFrames,
                retainedGapFrames <= frames(6_100));
            assertTrue(outputFrames < samples.length - frames(3_500));
        }
    }

    @Test
    public void profileParametersRemainInternallyValid() {
        assertTrue(
            BStreamSilenceSkippingProfile.MAX_SILENCE_TO_KEEP_DURATION_US
                >= BStreamSilenceSkippingProfile.MINIMUM_SILENCE_DURATION_US);
        assertEquals(64, BStreamSilenceSkippingProfile.SILENCE_THRESHOLD_LEVEL);
        assertEquals(20, BStreamSilenceSkippingProfile.MIN_VOLUME_TO_KEEP_PERCENTAGE);
    }

    private static long process(short[] samples) throws Exception {
        return process(samples, 1);
    }

    private static long process(short[] samples, int channelCount) throws Exception {
        BStreamSilenceSkippingAudioProcessor processor =
            BStreamSilenceSkippingProfile.createProcessor();
        processor.setEnabled(true);
        processor.configure(
            new AudioProcessor.AudioFormat(
                SAMPLE_RATE,
                channelCount,
                C.ENCODING_PCM_16BIT));
        processor.flush();

        ByteBuffer input = ByteBuffer.allocateDirect(samples.length * channelCount * 2)
            .order(ByteOrder.nativeOrder());
        for (short sample : samples) {
            for (int channel = 0; channel < channelCount; channel++) {
                input.putShort(sample);
            }
        }
        input.flip();

        long outputBytes = 0;
        int stalledIterations = 0;
        while (input.hasRemaining()) {
            int previousPosition = input.position();
            processor.queueInput(input);
            ByteBuffer output = processor.getOutput();
            outputBytes += output.remaining();
            if (input.position() == previousPosition && !output.hasRemaining()) {
                stalledIterations++;
                assertTrue("audio processor stopped consuming input", stalledIterations < 3);
            } else {
                stalledIterations = 0;
            }
        }

        processor.queueEndOfStream();
        for (int iteration = 0; !processor.isEnded(); iteration++) {
            assertTrue("audio processor did not finish", iteration < 10);
            ByteBuffer output = processor.getOutput();
            outputBytes += output.remaining();
        }
        processor.reset();
        return outputBytes / (channelCount * 2);
    }

    private static short[] silence(int milliseconds) {
        return new short[frames(milliseconds)];
    }

    private static short[] tone(int milliseconds, int peak) {
        short[] samples = new short[frames(milliseconds)];
        for (int index = 0; index < samples.length; index++) {
            double phase = 2.0 * Math.PI * 440.0 * index / SAMPLE_RATE;
            samples[index] = (short) Math.round(Math.sin(phase) * peak);
        }
        return samples;
    }

    private static short[] decayingTone(
            int milliseconds,
            int initialPeak,
            int finalPeak) {
        short[] samples = new short[frames(milliseconds)];
        double decay = Math.log((double) initialPeak / finalPeak);
        for (int index = 0; index < samples.length; index++) {
            double progress = (double) index / Math.max(1, samples.length - 1);
            double envelope = initialPeak * Math.exp(-decay * progress);
            double phase = 2.0 * Math.PI * 440.0 * index / SAMPLE_RATE;
            samples[index] = (short) Math.round(Math.sin(phase) * envelope);
        }
        return samples;
    }

    private static int frames(int milliseconds) {
        return SAMPLE_RATE * milliseconds / 1_000;
    }

    private static short[] concat(short[]... parts) {
        int length = 0;
        for (short[] part : parts) {
            length += part.length;
        }
        short[] result = new short[length];
        int offset = 0;
        for (short[] part : parts) {
            System.arraycopy(part, 0, result, offset, part.length);
            offset += part.length;
        }
        return result;
    }
}
