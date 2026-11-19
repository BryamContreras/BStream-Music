package com.ryanheise.just_audio;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.audio.AudioOffloadSupport;
import androidx.media3.exoplayer.audio.AudioSink;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Proxy;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public final class BStreamEqualizerAudioSinkTest {
    private static final int RATE = 48_000;
    private static final int CHANNELS = 2;
    private static final double[] CUT = {0, 0, 0, 0, 0, -6, 0, 0, 0, 0};

    @Test
    public void unsupportedFloatAndAudioTrackRejectionUseInt16WithoutLosingFrames() throws Exception {
        for (boolean canOpenFloat : new boolean[] {false, true}) {
            FakeSink delegate = new FakeSink();
            delegate.failFloatInitialization = canOpenFloat;
            delegate.maxBytesPerCall = 32;
            BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
            BStreamEqualizerAudioSink sink = new BStreamEqualizerAudioSink(
                    delegate.audioSink, state, true, format -> canOpenFloat);
            sink.configure(format(C.ENCODING_PCM_FLOAT), 0, null);

            ByteBuffer input = tone(128);
            finish(sink, input, 1234);

            assertEquals(C.ENCODING_PCM_16BIT, delegate.format.pcmEncoding);
            assertEquals(RATE, delegate.format.sampleRate);
            assertEquals(128 * CHANNELS * 2, delegate.written.size());
            for (long timestamp : delegate.timestamps) assertEquals(1234, timestamp);
        }
    }

    @Test
    public void offAndFlatForwardEveryOriginalPcmByteAndBuffer() throws Exception {
        for (int encoding : new int[] {
                C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT,
                C.ENCODING_PCM_24BIT, C.ENCODING_PCM_32BIT,
                C.ENCODING_PCM_24BIT_BIG_ENDIAN, C.ENCODING_PCM_32BIT_BIG_ENDIAN}) {
            for (boolean flat : new boolean[] {false, true}) {
                BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
                state.configure(flat, flat ? new double[BStreamEqualizerConfiguration.FREQUENCIES.length] : CUT);
                FakeSink delegate = new FakeSink();
                BStreamEqualizerAudioSink sink = sink(delegate, state, encoding, true);
                ByteBuffer input = patterned(encoding, 32);
                byte[] original = bytes(input);

                assertTrue(sink.handleBuffer(input, 123_456, 1));

                assertSame(input, delegate.buffers.get(0));
                assertArrayEquals(original, delegate.written.toByteArray());
                assertEquals(0, state.processedFrames());
                assertEquals(encoding, delegate.format.pcmEncoding);
                assertEquals(RATE, delegate.format.sampleRate);
                assertEquals(CHANNELS, delegate.format.channelCount);
                assertEquals(123_456L, delegate.timestamps.get(0).longValue());
                assertFalse(input.hasRemaining());
            }
        }
    }

    @Test
    public void floatBranchProcessesAudioWithoutChangingItsFormatOrFrameCount() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(true, CUT);
        FakeSink delegate = new FakeSink();
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        ByteBuffer input = tone(4096);
        byte[] original = bytes(input);

        assertTrue(sink.handleBuffer(input, 9_000, 1));

        byte[] output = delegate.written.toByteArray();
        assertNotSame(input, delegate.buffers.get(0));
        assertEquals(original.length, output.length);
        assertEquals(4096, state.processedFrames());
        assertEquals(C.ENCODING_PCM_FLOAT, state.encoding());
        double ratio = rms(output, 512) / rms(original, 512);
        assertTrue("1000 Hz should be attenuated by the selected -6 dB band: " + ratio,
                ratio > .4 && ratio < .65);
        // Sample processing reads the decoder buffer; it never modifies it.
        input.rewind();
        assertArrayEquals(original, bytes(input));
    }

    @Test
    public void processedPartialBufferIsNeverProcessedAgainWhileDisabling() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(true, CUT);
        FakeSink delegate = new FakeSink();
        delegate.maxBytesPerCall = 13;
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        ByteBuffer first = tone(128);

        assertFalse(sink.handleBuffer(first, 400, 1));
        assertEquals(128, state.processedFrames());
        ByteBuffer processed = delegate.buffers.get(0);
        state.configure(false, CUT);
        finish(sink, first, 400);

        assertEquals(128, state.processedFrames());
        for (ByteBuffer seen : delegate.buffers) assertSame(processed, seen);
        assertEquals(128 * CHANNELS * 4, delegate.written.size());
        for (long timestamp : delegate.timestamps) assertEquals(400, timestamp);

        // Let the short transition to flat settle in a following buffer.
        delegate.maxBytesPerCall = Integer.MAX_VALUE;
        assertTrue(sink.handleBuffer(tone(4096), 800, 1));
        long processedFrames = state.processedFrames();
        ByteBuffer bypassed = patterned(C.ENCODING_PCM_FLOAT, 32);
        assertTrue(sink.handleBuffer(bypassed, 1200, 1));
        assertSame(bypassed, delegate.buffers.get(delegate.buffers.size() - 1));
        assertEquals(processedFrames, state.processedFrames());
    }

    @Test
    public void directPartialBufferRemainsDirectWhenEqIsEnabledBetweenRetries() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        FakeSink delegate = new FakeSink();
        delegate.maxBytesPerCall = 7;
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        ByteBuffer direct = patterned(C.ENCODING_PCM_FLOAT, 32);
        byte[] original = bytes(direct);
        assertFalse(sink.handleBuffer(direct, 1234, 1));

        state.configure(true, CUT);
        finish(sink, direct, 1234);

        for (ByteBuffer seen : delegate.buffers) assertSame(direct, seen);
        assertArrayEquals(original, delegate.written.toByteArray());
        assertEquals(0, state.processedFrames());
        delegate.maxBytesPerCall = Integer.MAX_VALUE;
        ByteBuffer next = tone(128);
        assertTrue(sink.handleBuffer(next, 2345, 1));
        assertNotSame(next, delegate.buffers.get(delegate.buffers.size() - 1));
        assertEquals(128, state.processedFrames());
    }

    @Test
    public void eosDrainsPendingOutputBeforeDelegatingEndOfStream() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(true, CUT);
        FakeSink delegate = new FakeSink();
        delegate.maxBytesPerCall = 24;
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        assertFalse(sink.handleBuffer(tone(128), 555, 1));
        assertTrue(sink.hasPendingData());
        assertFalse(sink.isEnded());

        for (int attempt = 0; attempt < 100 && delegate.eosCalls == 0; attempt++) {
            sink.playToEndOfStream();
        }

        assertEquals(1, delegate.eosCalls);
        assertEquals(128 * CHANNELS * 4, delegate.bytesAtEos);
        assertEquals("eos", delegate.events.get(delegate.events.size() - 1));
        assertEquals(128, state.processedFrames());
        assertFalse(sink.hasPendingData());
        assertTrue(sink.isEnded());
    }

    @Test
    public void flushDropsPendingOwnershipAndResetsFilterHistory() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(true, CUT);
        FakeSink delegate = new FakeSink();
        delegate.maxBytesPerCall = 4;
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        assertFalse(sink.handleBuffer(tone(128), 400, 1));

        sink.flush();
        assertEquals(1, delegate.flushCalls);
        assertFalse(sink.hasPendingData());
        delegate.written.reset();
        delegate.maxBytesPerCall = Integer.MAX_VALUE;
        assertTrue(sink.handleBuffer(tone(256), 800, 1));

        BStreamEqualizerConfiguration freshState = new BStreamEqualizerConfiguration();
        freshState.configure(true, CUT);
        FakeSink fresh = new FakeSink();
        BStreamEqualizerAudioSink freshSink = sink(fresh, freshState, C.ENCODING_PCM_FLOAT, true);
        assertTrue(freshSink.handleBuffer(tone(256), 800, 1));
        assertArrayEquals(fresh.written.toByteArray(), delegate.written.toByteArray());

        sink.reset();
        assertEquals(1, delegate.resetCalls);
        assertFalse(sink.hasPendingData());
        sink.release();
        assertEquals(1, delegate.releaseCalls);
    }

    @Test
    public void pcm16AndNonFloatRouteBelongToTheDelegateProcessorChain() throws Exception {
        for (int[] route : new int[][] {
                {C.ENCODING_PCM_16BIT, 0}, {C.ENCODING_PCM_16BIT, 1},
                {C.ENCODING_PCM_24BIT, 0}}) {
            int encoding = route[0];
            BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
            state.configure(true, CUT);
            FakeSink delegate = new FakeSink();
            BStreamEqualizerAudioSink sink = sink(delegate, state, encoding, route[1] == 1);
            ByteBuffer input = patterned(encoding, 32);
            byte[] original = bytes(input);
            assertTrue(sink.handleBuffer(input, 0, 1));
            assertSame(input, delegate.buffers.get(0));
            assertArrayEquals(original, delegate.written.toByteArray());
            assertEquals(0, state.processedFrames());
        }
    }

    @Test
    public void policyKeepsDecodedPcmAndPreservesActualFloatSupport() throws Exception {
        for (boolean enabled : new boolean[] {false, true}) {
            BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
            state.configure(enabled, CUT);
            FakeSink delegate = new FakeSink();
            BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
            Format compressed = new Format.Builder().setSampleMimeType(MimeTypes.AUDIO_AAC).build();
            assertFalse(sink.supportsFormat(compressed));
            assertEquals(AudioSink.SINK_FORMAT_UNSUPPORTED, sink.getFormatSupport(compressed));
            assertSame(AudioOffloadSupport.DEFAULT_UNSUPPORTED, sink.getFormatOffloadSupport(compressed));
            sink.setOffloadMode(AudioSink.OFFLOAD_MODE_ENABLED_GAPLESS_NOT_REQUIRED);
            assertEquals(AudioSink.OFFLOAD_MODE_DISABLED, delegate.offloadMode);

            delegate.rawSupport = AudioSink.SINK_FORMAT_SUPPORTED_WITH_TRANSCODING;
            assertEquals(AudioSink.SINK_FORMAT_SUPPORTED_WITH_TRANSCODING,
                    sink.getFormatSupport(format(C.ENCODING_PCM_FLOAT)));
        }
    }

    @Test
    public void failedDspForwardsOriginalAudioReportsUnavailableAndRecoversOnNewFormat() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        state.configure(true, CUT);
        int[] changes = {0};
        state.setStatusListener(() -> changes[0]++);
        FakeSink delegate = new FakeSink();
        BStreamEqualizerAudioSink sink = sink(delegate, state, C.ENCODING_PCM_FLOAT, true);
        assertTrue(state.isConfigured());
        assertTrue(state.isAvailable());
        int configuredChanges = changes[0];
        ByteBuffer tone = tone(64);
        ByteBuffer malformed = ByteBuffer.allocateDirect(tone.remaining() + 1);
        malformed.put(tone).put((byte)37).flip();
        byte[] original = bytes(malformed);

        // A malformed PCM packet cannot preserve its frame count. Even after
        // reading it, optional DSP must rewind and deliver the original once.
        assertTrue(sink.handleBuffer(malformed, 99, 1));
        assertSame(malformed, delegate.buffers.get(0));
        assertArrayEquals(original, delegate.written.toByteArray());
        assertFalse(state.isAvailable());
        assertFalse(state.isConfigured());
        assertTrue(state.failure() != null);
        assertTrue(changes[0] > configuredChanges);
        long processed = state.processedFrames();

        ByteBuffer bypassed = tone(64);
        byte[] bypassedOriginal = bytes(bypassed);
        delegate.written.reset();
        assertTrue(sink.handleBuffer(bypassed, 100, 1));
        assertArrayEquals(bypassedOriginal, delegate.written.toByteArray());
        assertEquals(processed, state.processedFrames());
        assertFalse(state.isAvailable());

        sink.configure(format(C.ENCODING_PCM_FLOAT), 0, null);
        assertTrue(state.isAvailable());
        assertTrue(state.isConfigured());
        assertEquals(null, state.failure());
        delegate.written.reset();
        ByteBuffer recovered = tone(4096);
        byte[] recoveredOriginal = bytes(recovered);
        assertTrue(sink.handleBuffer(recovered, 200, 1));
        assertNotSame(recovered, delegate.buffers.get(delegate.buffers.size() - 1));
        double ratio = rms(delegate.written.toByteArray(), 512) / rms(recoveredOriginal, 512);
        assertTrue(ratio > .4 && ratio < .65);
    }

    @Test
    public void routeNotificationsOnlyTrackConfigurationTransitionsAndRespectOwner() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        int[] changes = {0};
        state.setStatusListener(() -> changes[0]++);
        Object oldRoute = new Object();
        Object newRoute = new Object();
        state.configured(oldRoute, 48000, 2, C.ENCODING_PCM_FLOAT);
        assertEquals(1, changes[0]);
        state.processed(100, 0);
        state.processed(100, 0);
        assertEquals(1, changes[0]);
        state.configured(newRoute, 44100, 1, C.ENCODING_PCM_16BIT);
        state.unconfigured(oldRoute);
        assertTrue(state.isConfigured());
        assertEquals(44100, state.sampleRate());
        state.unconfigured(newRoute);
        assertFalse(state.isConfigured());
        assertEquals(0, state.sampleRate());
        assertTrue(state.isAvailable());
        state.unavailable("failed route");
        assertFalse(state.isAvailable());
        int failedChanges = changes[0];
        state.unavailable("same failure");
        assertEquals(failedChanges, changes[0]);
        state.configured(newRoute, 48000, 2, C.ENCODING_PCM_FLOAT);
        assertTrue(state.isAvailable());
        state.setStatusListener(null);
        int disposedChanges = changes[0];
        state.unconfigured(newRoute);
        assertEquals(disposedChanges, changes[0]);
    }

    @Test
    public void processingRouteRecoversMetadataAfterAnOlderProcessorResets() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        BStreamEqualizerAudioProcessor oldRoute = new BStreamEqualizerAudioProcessor(state);
        BStreamEqualizerAudioProcessor currentRoute = new BStreamEqualizerAudioProcessor(state);
        AudioProcessor.AudioFormat format = new AudioProcessor.AudioFormat(
                RATE, CHANNELS, C.ENCODING_PCM_FLOAT);
        oldRoute.configure(format);
        oldRoute.flush();
        currentRoute.configure(format);
        currentRoute.flush();
        oldRoute.reset();
        currentRoute.queueInput(tone(64));
        assertTrue(state.isConfigured());
        assertTrue(state.isAvailable());
        assertEquals(RATE, state.sampleRate());
        assertEquals(CHANNELS, state.channelCount());
    }

    @Test
    public void drainingAnOldGenerationCannotRecoverAFailedNewRoute() throws Exception {
        BStreamEqualizerConfiguration state = new BStreamEqualizerConfiguration();
        AudioProcessor.AudioFormat format = new AudioProcessor.AudioFormat(
                RATE, CHANNELS, C.ENCODING_PCM_FLOAT);
        BStreamEqualizerAudioProcessor oldRoute = new BStreamEqualizerAudioProcessor(state);
        oldRoute.configure(format);
        oldRoute.flush();
        state.beginRoute();
        state.unavailable("new route failed");
        oldRoute.queueInput(tone(64));
        oldRoute.getOutput();
        oldRoute.flush();
        assertFalse(state.isAvailable());
        assertFalse(state.isConfigured());

        BStreamEqualizerAudioProcessor currentRoute = new BStreamEqualizerAudioProcessor(state);
        currentRoute.configure(format);
        currentRoute.flush();
        assertTrue(state.isAvailable());
        assertTrue(state.isConfigured());
        oldRoute.reset();
        assertTrue(state.isConfigured());
    }

    private static BStreamEqualizerAudioSink sink(
            FakeSink delegate, BStreamEqualizerConfiguration state, int encoding, boolean floatOutput)
            throws Exception {
        BStreamEqualizerAudioSink result = new BStreamEqualizerAudioSink(delegate.audioSink, state, floatOutput);
        result.configure(format(encoding), 0, null);
        return result;
    }

    private static Format format(int encoding) {
        return new Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW)
                .setSampleRate(RATE).setChannelCount(CHANNELS).setPcmEncoding(encoding).build();
    }

    private static void finish(BStreamEqualizerAudioSink sink, ByteBuffer input, long timestamp)
            throws Exception {
        for (int attempt = 0; attempt < 500; attempt++) {
            if (sink.handleBuffer(input, timestamp, 1)) return;
        }
        throw new AssertionError("Partial output did not drain");
    }

    private static ByteBuffer patterned(int encoding, int frames) {
        int width = encoding == C.ENCODING_PCM_16BIT ? 2
                : (encoding == C.ENCODING_PCM_24BIT || encoding == C.ENCODING_PCM_24BIT_BIG_ENDIAN ? 3 : 4);
        ByteBuffer result = ByteBuffer.allocateDirect(frames * CHANNELS * width);
        while (result.hasRemaining()) result.put((byte)(result.position() * 37 + 11));
        result.flip();
        return result;
    }

    private static ByteBuffer tone(int frames) {
        ByteBuffer result = ByteBuffer.allocateDirect(frames * CHANNELS * 4).order(ByteOrder.LITTLE_ENDIAN);
        for (int frame = 0; frame < frames; frame++) {
            float sample = (float)(.2 * Math.sin(2 * Math.PI * 1000 * frame / RATE));
            for (int channel = 0; channel < CHANNELS; channel++) result.putFloat(sample);
        }
        result.flip();
        return result;
    }

    private static byte[] bytes(ByteBuffer buffer) {
        ByteBuffer copy = buffer.duplicate();
        byte[] bytes = new byte[copy.remaining()];
        copy.get(bytes);
        return bytes;
    }

    private static double rms(byte[] bytes, int skipFrames) {
        ByteBuffer buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        buffer.position(skipFrames * CHANNELS * 4);
        double total = 0;
        int count = 0;
        while (buffer.hasRemaining()) {
            double sample = buffer.getFloat();
            total += sample * sample;
            count++;
        }
        return Math.sqrt(total / count);
    }

    /** Only models the AudioSink contract; it performs no Android or device calls. */
    private static final class FakeSink {
        final ByteArrayOutputStream written = new ByteArrayOutputStream();
        final List<ByteBuffer> buffers = new ArrayList<>();
        final List<Long> timestamps = new ArrayList<>();
        final List<String> events = new ArrayList<>();
        int maxBytesPerCall = Integer.MAX_VALUE;
        int rawSupport = AudioSink.SINK_FORMAT_SUPPORTED_DIRECTLY;
        int offloadMode = -1;
        int eosCalls;
        int bytesAtEos;
        int flushCalls;
        int resetCalls;
        int releaseCalls;
        boolean failFloatInitialization;
        Format format;

        final AudioSink audioSink = (AudioSink)Proxy.newProxyInstance(
                AudioSink.class.getClassLoader(), new Class<?>[] {AudioSink.class},
                (proxy, method, arguments) -> {
                    switch (method.getName()) {
                        case "configure":
                            format = (Format)arguments[0];
                            return null;
                        case "getFormatSupport": return rawSupport;
                        case "supportsFormat": return true;
                        case "handleBuffer":
                            if (failFloatInitialization && format.pcmEncoding == C.ENCODING_PCM_FLOAT) {
                                throw new AudioSink.InitializationException(
                                        0, RATE, CHANNELS, 0, format, false, null);
                            }
                            ByteBuffer buffer = (ByteBuffer)arguments[0];
                            buffers.add(buffer);
                            timestamps.add((Long)arguments[1]);
                            int count = Math.min(maxBytesPerCall, buffer.remaining());
                            for (int i = 0; i < count; i++) written.write(buffer.get() & 255);
                            events.add("write");
                            return !buffer.hasRemaining();
                        case "setOffloadMode":
                            offloadMode = (Integer)arguments[0];
                            return null;
                        case "playToEndOfStream":
                            eosCalls++;
                            bytesAtEos = written.size();
                            events.add("eos");
                            return null;
                        case "isEnded": return eosCalls > 0;
                        case "hasPendingData": return false;
                        case "flush": flushCalls++; return null;
                        case "reset": resetCalls++; return null;
                        case "release": releaseCalls++; return null;
                        default:
                            if (method.getReturnType() == boolean.class) return false;
                            if (method.getReturnType() == long.class) return 0L;
                            if (method.getReturnType() == int.class) return 0;
                            return null;
                    }
                });
    }
}
