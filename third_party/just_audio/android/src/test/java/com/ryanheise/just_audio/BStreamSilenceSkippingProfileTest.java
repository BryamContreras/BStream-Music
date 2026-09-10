package com.ryanheise.just_audio;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;
import org.junit.Test;

public final class BStreamSilenceSkippingProfileTest {
    private static final int SAMPLE_RATE = 16_000;

    @Test
    public void internalPausesUpToFourSecondsRemainBitExact() throws Exception {
        for (int pauseMilliseconds : new int[] {3_000, 4_000}) {
            short[] samples = concat(
                tone(600, 2_800),
                silence(pauseMilliseconds),
                tone(600, 2_800));

            for (int channelCount : new int[] {1, 2, 6}) {
                ProcessResult result = process(samples, channelCount, 0, Integer.MAX_VALUE);
                assertEquals(samples.length, result.outputFrames);
                assertEquals(0, result.skippedFrames);
                assertArrayEquals(samples, result.selectedChannelSamples);
            }
        }
    }

    @Test
    public void internalPauseUsesFourPointFiveSecondThreshold() throws Exception {
        short[] protectedPause = concat(
            tone(600, 2_800),
            silence(4_400),
            tone(600, 2_800));
        assertEquals(protectedPause.length, process(protectedPause).outputFrames);

        short[] removablePause = concat(
            tone(600, 2_800),
            silence(4_800),
            tone(600, 2_800));
        ProcessResult shortened = process(removablePause);
        long retainedPauseFrames = shortened.outputFrames - frames(1_200);
        assertTrue(retainedPauseFrames >= frames(350));
        assertTrue(retainedPauseFrames <= frames(700));
        assertEquals(removablePause.length, shortened.outputFrames + shortened.skippedFrames);
    }

    @Test
    public void introUsesEdgeThresholdButUnsignalledOutroUsesInternalThreshold()
            throws Exception {
        short[] shortIntro = concat(silence(1_700), tone(600, 2_800));
        short[] shortOutro = concat(tone(600, 2_800), silence(1_700));
        assertEquals(shortIntro.length, process(shortIntro).outputFrames);
        assertEquals(shortOutro.length, process(shortOutro).outputFrames);

        short[] longIntro = concat(silence(2_200), tone(600, 2_800));
        short[] intermediateOutro = concat(tone(600, 2_800), silence(2_200));
        short[] longOutro = concat(tone(600, 2_800), silence(5_200));
        ProcessResult introResult = process(longIntro);
        ProcessResult intermediateOutroResult = process(intermediateOutro);
        ProcessResult outroResult = process(longOutro);
        assertTrue(introResult.skippedFrames >= frames(1_700));
        assertEquals(0, intermediateOutroResult.skippedFrames);
        assertArrayEquals(intermediateOutro, intermediateOutroResult.selectedChannelSamples);
        assertTrue(outroResult.skippedFrames >= frames(4_500));
        assertEquals(longIntro.length, introResult.outputFrames + introResult.skippedFrames);
        assertEquals(intermediateOutro.length,
            intermediateOutroResult.outputFrames + intermediateOutroResult.skippedFrames);
        assertEquals(longOutro.length, outroResult.outputFrames + outroResult.skippedFrames);
    }

    @Test
    public void repeatedFlushAndToggleCannotTurnMiddleIntoShortEdge() throws Exception {
        short[] samplesAfterFlush = concat(
            silence(2_200),
            tone(600, 2_800));
        BStreamSilenceSkippingAudioProcessor processor = configuredProcessor();
        ShortAccumulator discardedFirstStream = new ShortAccumulator();
        try {
            queueMono(processor, tone(600, 2_800), 173, discardedFirstStream);
            finishMono(processor, discardedFirstStream);

            // Model the drain/flush sequence Media3 performs for processor changes. Neither the
            // disabled flush nor the following enabled flush is proof of a real stream edge.
            processor.setEnabled(false);
            processor.flush();
            processor.setEnabled(true);
            processor.flush();

            ShortAccumulator output = new ShortAccumulator();
            queueMono(processor, samplesAfterFlush, 173, output);
            finishMono(processor, output);

            assertEquals(0, processor.getSkippedFrames());
            assertArrayEquals(samplesAfterFlush, output.toArray());
        } finally {
            processor.reset();
        }
    }

    @Test
    public void resetThenConfigureStartsAFreshUnambiguousEdge() throws Exception {
        short[] intro = concat(silence(2_200), tone(600, 2_800));
        BStreamSilenceSkippingAudioProcessor processor = configuredProcessor();
        try {
            // Consume the first-flush edge privilege, then verify reset fulfils the reusable
            // AudioProcessor contract and allows a genuinely fresh configuration to have it.
            processor.flush();
            processor.reset();
            processor.setEnabled(true);
            processor.configure(new AudioProcessor.AudioFormat(
                SAMPLE_RATE,
                1,
                C.ENCODING_PCM_16BIT));
            processor.flush();

            ShortAccumulator output = new ShortAccumulator();
            queueMono(processor, intro, 173, output);
            finishMono(processor, output);

            assertTrue(processor.getSkippedFrames() >= frames(1_700));
            assertEquals(intro.length,
                output.toArray().length + processor.getSkippedFrames());
        } finally {
            processor.reset();
        }
    }

    @Test
    public void musicalPeakGuardProtectsVeryQuietInstrumentation() throws Exception {
        short[] samples = concat(
            tone(600, 2_800),
            tone(6_000, 80),
            tone(600, 2_800));

        for (int channelCount : new int[] {1, 2, 6}) {
            ProcessResult result = process(samples, channelCount, channelCount - 1, 173);
            assertEquals(samples.length, result.outputFrames);
            assertEquals(0, result.skippedFrames);
            assertArrayEquals(samples, result.selectedChannelSamples);
        }
    }

    @Test
    public void fourSecondReverbTailRemainsUntouched() throws Exception {
        short[] samples = concat(
            tone(600, 2_800),
            decayingTone(4_000, 4_096, 16),
            tone(600, 2_800));

        ProcessResult result = process(samples);
        assertEquals(samples.length, result.outputFrames);
        assertEquals(0, result.skippedFrames);
        assertArrayEquals(samples, result.selectedChannelSamples);
    }

    @Test
    public void exitThresholdBreaksAProspectiveSilenceImmediately() throws Exception {
        short[] samples = concat(
            tone(600, 2_800),
            silence(2_600),
            constant(300, 200),
            silence(2_600),
            tone(600, 2_800));

        ProcessResult result = process(samples);
        assertEquals(samples.length, result.outputFrames);
        assertEquals(0, result.skippedFrames);
        assertArrayEquals(samples, result.selectedChannelSamples);
    }

    @Test
    public void sparseMusicalPeakCancelsInsteadOfBeingOutvotedBySilence() throws Exception {
        // The 100 ms tone occupies less than 10% of this otherwise empty edge. It still has to
        // veto removal; the 90% rule must never outvote protected musical evidence.
        short[] samples = concat(
            silence(1_050),
            tone(100, 80),
            silence(1_050),
            tone(600, 2_800));

        ProcessResult result = process(samples);
        assertEquals(samples.length, result.outputFrames);
        assertEquals(0, result.skippedFrames);
        assertArrayEquals(samples, result.selectedChannelSamples);
    }

    @Test
    public void cancellingPeakAtCandidateBoundaryRemainsBitExact() throws Exception {
        // The hysteresis bed keeps the processor out of an active silence candidate. Once its
        // smoothed power decays, this isolated peak is the last evidence that vetoes removal.
        // It sits more than the 150 ms leading keep inside the 325 ms analysis lookbehind, so a
        // candidate must never absorb the whole lookbehind and subsequently discard the peak.
        short[] sentinel = new short[] {80};
        short[] protectedPrefix = concat(
            constant(1_000, 100),
            silence(50),
            sentinel);
        short[] samples = concat(
            protectedPrefix,
            silence(5_200),
            tone(600, 2_800));

        ProcessResult result = process(samples, 1, 0, 173);

        assertTrue("the long empty suffix must still be shortened",
            result.skippedFrames >= frames(4_500));
        assertTrue(result.selectedChannelSamples.length >= protectedPrefix.length);
        assertArrayEquals(
            "PCM through the cancelling peak must be preserved bit-exact",
            protectedPrefix,
            Arrays.copyOf(result.selectedChannelSamples, protectedPrefix.length));
        assertEquals(samples.length, result.outputFrames + result.skippedFrames);
    }

    @Test
    public void continuousHysteresisBandAudioIsReleasedBeforeEdgeMinimum() throws Exception {
        // Constant 100 is about -50.3 dBFS: above entry, below exit. Once enough non-silent
        // votes make 90% mathematically impossible, the intro candidate should be rejected early.
        short[] samples = constant(2_200, 100);
        int consumedBeforeOutput = framesConsumedBeforeFirstOutput(samples, frames(25));

        assertTrue(consumedBeforeOutput >= frames(200));
        assertTrue(consumedBeforeOutput < frames(800));
        ProcessResult result = process(samples);
        assertEquals(samples.length, result.outputFrames);
        assertEquals(0, result.skippedFrames);
        assertArrayEquals(samples, result.selectedChannelSamples);
    }

    @Test
    public void processingIsInvariantAcrossInputChunksAndAccountsForEveryFrame()
            throws Exception {
        short[] samples = concat(
            tone(700, 2_800),
            silence(5_600),
            tone(700, 2_800),
            silence(2_300));

        ProcessResult singleBuffer = process(samples, 2, 0, Integer.MAX_VALUE);
        ProcessResult irregularChunks = process(samples, 2, 0, 137);
        assertEquals(singleBuffer.outputFrames, irregularChunks.outputFrames);
        assertEquals(singleBuffer.skippedFrames, irregularChunks.skippedFrames);
        assertArrayEquals(
            singleBuffer.selectedChannelSamples,
            irregularChunks.selectedChannelSamples);
        assertEquals(samples.length, irregularChunks.outputFrames + irregularChunks.skippedFrames);
    }

    @Test
    public void audibleMarkerAfterConfirmedSilenceIsEmittedExactlyOnce() throws Exception {
        short[] marker = audibleMarker(40);
        short[] samples = concat(
            tone(600, 2_800),
            silence(5_200),
            marker,
            tone(600, 2_800));

        ProcessResult result = process(samples, 1, 0, 137);

        assertTrue("the long internal silence must be confirmed and shortened",
            result.skippedFrames >= frames(4_500));
        assertEquals(samples.length, result.outputFrames + result.skippedFrames);
        assertEquals(
            "the first audible block after confirmed silence must be preserved exactly once",
            1,
            countOccurrences(result.selectedChannelSamples, marker));
    }

    @Test
    public void singleFrameLittleEndianSlicesRespectPositionAndLimit() throws Exception {
        short[] samples = tone(120, 2_800);

        ProcessResult result = processPaddedLittleEndianSlices(samples, 2, 1);

        assertEquals(samples.length, result.outputFrames);
        assertEquals(0, result.skippedFrames);
        assertArrayEquals(samples, result.selectedChannelSamples);
    }

    @Test
    public void twentyMillisecondSampleDomainSpliceReachesZero() throws Exception {
        short[] samples = concat(
            tone(600, 2_800),
            constant(5_000, 40),
            tone(600, 2_800));
        ProcessResult result = process(samples);

        assertTrue(result.skippedFrames >= frames(4_500));
        int expectedFadeOutEnd = frames(600 + 150) - 1;
        int searchRadius = frames(30);
        boolean foundZeroNearSplice = false;
        for (int index = Math.max(0, expectedFadeOutEnd - searchRadius);
                index <= Math.min(result.selectedChannelSamples.length - 1,
                    expectedFadeOutEnd + searchRadius);
                index++) {
            if (result.selectedChannelSamples[index] == 0) {
                foundZeroNearSplice = true;
                break;
            }
        }
        assertTrue("fade-out must reach zero at the PCM splice", foundZeroNearSplice);
    }

    @Test
    public void profileParametersRemainInternallyValid() {
        assertEquals(100_000L, BStreamSilenceSkippingProfile.ANALYSIS_WINDOW_US);
        assertEquals(25_000L, BStreamSilenceSkippingProfile.ANALYSIS_HOP_US);
        assertEquals(250_000L, BStreamSilenceSkippingProfile.RMS_SMOOTHING_US);
        assertEquals(-52.0, BStreamSilenceSkippingProfile.ENTER_SILENCE_DBFS, 0.0);
        assertEquals(-46.0, BStreamSilenceSkippingProfile.EXIT_SILENCE_DBFS, 0.0);
        assertEquals(90, BStreamSilenceSkippingProfile.REQUIRED_SILENT_WINDOW_PERCENTAGE);
        assertEquals(1_800_000L,
            BStreamSilenceSkippingProfile.EDGE_MINIMUM_SILENCE_DURATION_US);
        assertEquals(4_500_000L,
            BStreamSilenceSkippingProfile.INTERNAL_MINIMUM_SILENCE_DURATION_US);
        assertEquals(150_000L, BStreamSilenceSkippingProfile.LEADING_SILENCE_TO_KEEP_US);
        assertEquals(250_000L, BStreamSilenceSkippingProfile.TRAILING_SILENCE_TO_KEEP_US);
        assertEquals(800_000L, BStreamSilenceSkippingProfile.FADE_PROTECTION_DURATION_US);
        assertEquals(20_000L, BStreamSilenceSkippingProfile.SPLICE_FADE_DURATION_US);
        assertEquals(64, BStreamSilenceSkippingProfile.MUSICAL_PEAK_GUARD_LEVEL);
        assertTrue(BStreamSilenceSkippingProfile.EXIT_SILENCE_DBFS
            > BStreamSilenceSkippingProfile.ENTER_SILENCE_DBFS);
    }

    private static ProcessResult process(short[] samples) throws Exception {
        return process(samples, 1, 0, Integer.MAX_VALUE);
    }

    private static BStreamSilenceSkippingAudioProcessor configuredProcessor()
            throws Exception {
        BStreamSilenceSkippingAudioProcessor processor =
            BStreamSilenceSkippingProfile.createProcessor();
        processor.setEnabled(true);
        processor.configure(new AudioProcessor.AudioFormat(
            SAMPLE_RATE,
            1,
            C.ENCODING_PCM_16BIT));
        processor.flush();
        return processor;
    }

    private static void queueMono(
            BStreamSilenceSkippingAudioProcessor processor,
            short[] samples,
            int chunkFrames,
            ShortAccumulator output) {
        int inputFrame = 0;
        while (inputFrame < samples.length) {
            int framesInChunk = Math.min(chunkFrames, samples.length - inputFrame);
            ByteBuffer input = ByteBuffer.allocateDirect(framesInChunk * 2)
                .order(ByteOrder.nativeOrder());
            for (int frame = 0; frame < framesInChunk; frame++) {
                input.putShort(samples[inputFrame + frame]);
            }
            input.flip();
            while (input.hasRemaining()) {
                int previousPosition = input.position();
                processor.queueInput(input);
                drainOutput(processor.getOutput(), 1, 0, output);
                assertTrue("audio processor stopped consuming input",
                    input.position() > previousPosition);
            }
            inputFrame += framesInChunk;
        }
    }

    private static void finishMono(
            BStreamSilenceSkippingAudioProcessor processor,
            ShortAccumulator output) {
        processor.queueEndOfStream();
        for (int iteration = 0; !processor.isEnded(); iteration++) {
            assertTrue("audio processor did not finish", iteration < 10);
            drainOutput(processor.getOutput(), 1, 0, output);
        }
    }

    private static int framesConsumedBeforeFirstOutput(short[] samples, int chunkFrames)
            throws Exception {
        BStreamSilenceSkippingAudioProcessor processor =
            BStreamSilenceSkippingProfile.createProcessor();
        processor.setEnabled(true);
        processor.configure(new AudioProcessor.AudioFormat(
            SAMPLE_RATE,
            1,
            C.ENCODING_PCM_16BIT));
        processor.flush();
        try {
            int inputFrame = 0;
            while (inputFrame < samples.length) {
                int framesInChunk = Math.min(chunkFrames, samples.length - inputFrame);
                ByteBuffer input = ByteBuffer.allocateDirect(framesInChunk * 2)
                    .order(ByteOrder.nativeOrder());
                for (int frame = 0; frame < framesInChunk; frame++) {
                    input.putShort(samples[inputFrame + frame]);
                }
                input.flip();
                processor.queueInput(input);
                assertEquals(input.limit(), input.position());
                inputFrame += framesInChunk;
                if (processor.getOutput().hasRemaining()) {
                    return inputFrame;
                }
            }
            return samples.length;
        } finally {
            processor.reset();
        }
    }

    private static ProcessResult process(
            short[] samples,
            int channelCount,
            int selectedChannel,
            int chunkFrames) throws Exception {
        BStreamSilenceSkippingAudioProcessor processor =
            BStreamSilenceSkippingProfile.createProcessor();
        processor.setEnabled(true);
        processor.configure(
            new AudioProcessor.AudioFormat(SAMPLE_RATE, channelCount, C.ENCODING_PCM_16BIT));
        processor.flush();

        ShortAccumulator selectedOutput = new ShortAccumulator();
        int inputFrame = 0;
        while (inputFrame < samples.length) {
            int framesInChunk = Math.min(chunkFrames, samples.length - inputFrame);
            ByteBuffer input = ByteBuffer.allocateDirect(framesInChunk * channelCount * 2)
                .order(ByteOrder.nativeOrder());
            for (int frame = 0; frame < framesInChunk; frame++) {
                short sample = samples[inputFrame + frame];
                for (int channel = 0; channel < channelCount; channel++) {
                    input.putShort(channel == selectedChannel ? sample : (short) 0);
                }
            }
            input.flip();
            int stalledIterations = 0;
            while (input.hasRemaining()) {
                int previousPosition = input.position();
                processor.queueInput(input);
                drainOutput(processor.getOutput(), channelCount, selectedChannel, selectedOutput);
                if (input.position() == previousPosition) {
                    stalledIterations++;
                    assertTrue("audio processor stopped consuming input", stalledIterations < 3);
                } else {
                    stalledIterations = 0;
                }
            }
            inputFrame += framesInChunk;
        }

        processor.queueEndOfStream();
        for (int iteration = 0; !processor.isEnded(); iteration++) {
            assertTrue("audio processor did not finish", iteration < 10);
            drainOutput(processor.getOutput(), channelCount, selectedChannel, selectedOutput);
        }
        long skippedFrames = processor.getSkippedFrames();
        short[] outputSamples = selectedOutput.toArray();
        processor.reset();
        return new ProcessResult(outputSamples.length, skippedFrames, outputSamples);
    }

    private static ProcessResult processPaddedLittleEndianSlices(
            short[] samples,
            int channelCount,
            int selectedChannel) throws Exception {
        BStreamSilenceSkippingAudioProcessor processor =
            BStreamSilenceSkippingProfile.createProcessor();
        processor.setEnabled(true);
        processor.configure(
            new AudioProcessor.AudioFormat(SAMPLE_RATE, channelCount, C.ENCODING_PCM_16BIT));
        processor.flush();

        ShortAccumulator selectedOutput = new ShortAccumulator();
        int bytesPerFrame = channelCount * 2;
        int prefixBytes = 3;
        int suffixBytes = 5;
        try {
            for (short sample : samples) {
                ByteBuffer input = ByteBuffer
                    .allocateDirect(prefixBytes + bytesPerFrame + suffixBytes)
                    .order(ByteOrder.LITTLE_ENDIAN);
                while (input.position() < prefixBytes) {
                    input.put((byte) 0x55);
                }
                for (int channel = 0; channel < channelCount; channel++) {
                    input.putShort(channel == selectedChannel ? sample : (short) 0);
                }
                int audioLimit = input.position();
                while (input.hasRemaining()) {
                    input.put((byte) 0x66);
                }
                input.limit(audioLimit);
                input.position(prefixBytes);

                while (input.hasRemaining()) {
                    int previousPosition = input.position();
                    processor.queueInput(input);
                    drainOutput(
                        processor.getOutput(),
                        channelCount,
                        selectedChannel,
                        selectedOutput);
                    assertTrue("audio processor stopped consuming input",
                        input.position() > previousPosition);
                }
                assertEquals(audioLimit, input.position());
            }

            processor.queueEndOfStream();
            for (int iteration = 0; !processor.isEnded(); iteration++) {
                assertTrue("audio processor did not finish", iteration < 10);
                drainOutput(
                    processor.getOutput(),
                    channelCount,
                    selectedChannel,
                    selectedOutput);
            }
            long skippedFrames = processor.getSkippedFrames();
            short[] outputSamples = selectedOutput.toArray();
            return new ProcessResult(outputSamples.length, skippedFrames, outputSamples);
        } finally {
            processor.reset();
        }
    }

    private static void drainOutput(
            ByteBuffer output,
            int channelCount,
            int selectedChannel,
            ShortAccumulator selectedOutput) {
        output.order(ByteOrder.nativeOrder());
        while (output.remaining() >= channelCount * 2) {
            for (int channel = 0; channel < channelCount; channel++) {
                short sample = output.getShort();
                if (channel == selectedChannel) {
                    selectedOutput.append(sample);
                }
            }
        }
        assertEquals(0, output.remaining());
    }

    private static short[] silence(int milliseconds) {
        return new short[frames(milliseconds)];
    }

    private static short[] constant(int milliseconds, int value) {
        short[] samples = new short[frames(milliseconds)];
        Arrays.fill(samples, (short) value);
        return samples;
    }

    private static short[] tone(int milliseconds, int peak) {
        short[] samples = new short[frames(milliseconds)];
        for (int index = 0; index < samples.length; index++) {
            double phase = 2.0 * Math.PI * 440.0 * index / SAMPLE_RATE;
            samples[index] = (short) Math.round(Math.sin(phase) * peak);
        }
        return samples;
    }

    private static short[] audibleMarker(int milliseconds) {
        short[] samples = new short[frames(milliseconds)];
        for (int index = 0; index < samples.length; index++) {
            int magnitude = 12_000 + index * 17;
            samples[index] = (short) (index % 2 == 0 ? magnitude : -magnitude);
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

    private static int countOccurrences(short[] samples, short[] target) {
        int occurrences = 0;
        for (int start = 0; start <= samples.length - target.length; start++) {
            boolean matches = true;
            for (int index = 0; index < target.length; index++) {
                if (samples[start + index] != target[index]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                occurrences++;
            }
        }
        return occurrences;
    }

    private static final class ShortAccumulator {
        private short[] samples = new short[8_192];
        private int size;

        void append(short sample) {
            if (size == samples.length) {
                samples = Arrays.copyOf(samples, samples.length * 2);
            }
            samples[size++] = sample;
        }

        short[] toArray() {
            return Arrays.copyOf(samples, size);
        }
    }

    private static final class ProcessResult {
        final long outputFrames;
        final long skippedFrames;
        final short[] selectedChannelSamples;

        ProcessResult(long outputFrames, long skippedFrames, short[] selectedChannelSamples) {
            this.outputFrames = outputFrames;
            this.skippedFrames = skippedFrames;
            this.selectedChannelSamples = selectedChannelSamples;
        }
    }
}
