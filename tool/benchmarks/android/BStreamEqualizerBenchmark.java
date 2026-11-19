package com.ryanheise.just_audio;

import android.os.Build;
import android.os.Debug;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Random;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * ART-side throughput benchmark of the production processor, without Flutter,
 * a decoder, speakers or a test implementation of the filters. A 10 ms PCM
 * block goes through queueInput/getOutput, exactly as in Media3's processor
 * chain. CPU time is for this one thread, not whole-app or battery usage.
 */
public final class BStreamEqualizerBenchmark {
    private static volatile long consumed;
    private static final int CHANNELS = 2;
    private static final int BLOCKS_PER_SECOND = 100;

    private static final class Scenario {
        final String name;
        final boolean enabled;
        final double[][] curves;

        Scenario(String name, boolean enabled, double[] gains) {
            this(name, enabled, new double[][] {gains});
        }

        Scenario(String name, boolean enabled, double[][] curves) {
            this.name = name;
            this.enabled = enabled;
            this.curves = curves;
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 4) throw new IllegalArgumentException("preset JSON, repetitions, seconds, label required");
        int repetitions = Integer.parseInt(args[1]);
        double seconds = Double.parseDouble(args[2]);
        if (repetitions < 3 || repetitions > 20 || seconds < .5 || seconds > 20) {
            throw new IllegalArgumentException("Use 3..20 repetitions and 0.5..20 seconds of audio per repetition");
        }
        JSONObject presets = readJson(args[0]);
        List<Scenario> scenarios = scenarios(presets.getJSONObject("presets"));
        System.out.println(new JSONObject()
                .put("type", "metadata").put("label", args[3])
                .put("runtime", "Android ART app_process; production Media3 processor")
                .put("model", Build.MODEL).put("abi", Build.SUPPORTED_ABIS[0])
                .put("sdk", Build.VERSION.SDK_INT).put("repetitions", repetitions)
                .put("audioSecondsPerRepetition", seconds).put("blockDurationMs", 10)
                .put("channels", CHANNELS).put("scenarioCount", scenarios.size())
                .put("note", "Saturated throughput; CPU ms/audio s is one-thread work, not whole-app CPU or battery"));

        // Prime the same production branches for both PCM encodings before
        // comparing scenarios. Each case also warms its own steady state.
        for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
            Lane warm = new Lane(48000, encoding, new Scenario("warm", true, filled(6)));
            warm.run(1200, false, null);
            warm.close();
        }

        int group = 0;
        for (int rate : new int[] {48000, 96000}) {
            for (int encoding : new int[] {C.ENCODING_PCM_16BIT, C.ENCODING_PCM_FLOAT}) {
                List<Scenario> ordered = new ArrayList<>(scenarios);
                Collections.shuffle(ordered, new Random(89317 + group++));
                for (Scenario scenario : ordered) {
                    measure(args[3], rate, encoding, scenario, repetitions, seconds);
                }
            }
        }
        System.out.println(new JSONObject().put("type", "complete").put("checksum", consumed));
    }

    private static void measure(String label, int rate, int encoding, Scenario scenario,
                                int repetitions, double seconds) throws Exception {
        Lane lane = new Lane(rate, encoding, scenario);
        // 3 seconds of audio, not a timed sleep. This excludes initial buffer
        // allocation and the initial 25 ms ramp from the steady-state result.
        lane.run(300, false, null);
        int blocks = (int)Math.round(seconds * BLOCKS_PER_SECOND);
        double actualSeconds = blocks / (double)BLOCKS_PER_SECOND;
        double[] cpuMsPerAudioSecond = new double[repetitions];
        double[] wallMsPerAudioSecond = new double[repetitions];
        long[] blockWall = new long[blocks * repetitions];
        BlockWindow[] windows = new BlockWindow[repetitions];
        for (int repetition = 0; repetition < repetitions; repetition++) {
            windows[repetition] = new BlockWindow(blockWall, repetition * blocks);
        }
        long gcBefore = runtimeStat("art.gc.gc-count");
        long allocatedBefore = runtimeStat("art.gc.bytes-allocated");
        for (int repetition = 0; repetition < repetitions; repetition++) {
            long cpuStart = Debug.threadCpuTimeNanos();
            long wallStart = System.nanoTime();
            lane.run(blocks, true, windows[repetition]);
            long wallElapsed = System.nanoTime() - wallStart;
            long cpuElapsed = Debug.threadCpuTimeNanos() - cpuStart;
            cpuMsPerAudioSecond[repetition] = cpuElapsed / 1e6 / actualSeconds;
            wallMsPerAudioSecond[repetition] = wallElapsed / 1e6 / actualSeconds;
        }
        long allocated = runtimeStat("art.gc.bytes-allocated") - allocatedBefore;
        long collections = runtimeStat("art.gc.gc-count") - gcBefore;
        lane.verifyLastOutput();
        double medianCpu = percentile(cpuMsPerAudioSecond, .5);
        int deadlineMisses = 0;
        for (long elapsed : blockWall) if (elapsed >= 10000000L) deadlineMisses++;
        System.out.println(new JSONObject()
                .put("type", "case").put("label", label).put("scenario", scenario.name)
                .put("sampleRate", rate).put("pcm", encoding == C.ENCODING_PCM_FLOAT ? "float32" : "s16")
                .put("channels", CHANNELS).put("repetitions", repetitions)
                .put("audioSecondsPerRepetition", actualSeconds)
                .put("medianCpuMsPerAudioSecond", medianCpu)
                .put("p95CpuMsPerAudioSecond", percentile(cpuMsPerAudioSecond, .95))
                .put("equivalentSingleCorePercent", medianCpu / 10)
                .put("medianWallMsPerAudioSecond", percentile(wallMsPerAudioSecond, .5))
                .put("p95BlockWallUs", percentile(blockWall, .95) / 1000)
                .put("maxBlockWallUs", percentile(blockWall, 1) / 1000)
                .put("blocksAtOrAbove10ms", deadlineMisses)
                .put("measuredBlocks", blockWall.length)
                .put("gcCollectionsDuringMeasurement", collections)
                .put("allocatedBytesDuringMeasurement", allocated)
                .put("lastOutputPeak", lane.lastPeak)
                .put("bypassExact", lane.bypassExact)
                .put("checksum", lane.checksum));
        lane.close();
    }

    private static final class BlockWindow {
        final long[] values;
        final int start;
        BlockWindow(long[] values, int start) { this.values = values; this.start = start; }
    }

    private static final class Lane {
        final int rate;
        final int encoding;
        final Scenario scenario;
        final BStreamEqualizerConfiguration configuration = new BStreamEqualizerConfiguration();
        final BStreamEqualizerAudioProcessor processor;
        final ByteBuffer input;
        final byte[] reference;
        ByteBuffer last;
        long checksum;
        long sequence;
        double lastPeak;
        boolean bypassExact;

        Lane(int rate, int encoding, Scenario scenario) throws Exception {
            this.rate = rate;
            this.encoding = encoding;
            this.scenario = scenario;
            configuration.configure(scenario.enabled, scenario.curves[0]);
            processor = new BStreamEqualizerAudioProcessor(configuration);
            AudioProcessor.AudioFormat format = new AudioProcessor.AudioFormat(rate, CHANNELS, encoding);
            processor.configure(format);
            processor.flush();
            input = ByteBuffer.allocateDirect(rate / BLOCKS_PER_SECOND * format.bytesPerFrame)
                    .order(ByteOrder.LITTLE_ENDIAN);
            for (int frame = 0; frame < rate / BLOCKS_PER_SECOND; frame++) {
                for (int channel = 0; channel < CHANNELS; channel++) {
                    double sample = 0;
                    for (double frequency : BStreamEqualizerConfiguration.FREQUENCIES) {
                        sample += .018 * Math.sin(2 * Math.PI * frequency * frame / rate + channel * .37);
                    }
                    if (encoding == C.ENCODING_PCM_FLOAT) input.putFloat((float)sample);
                    else input.putShort((short)Math.round(sample * 32768));
                }
            }
            input.flip();
            reference = new byte[input.remaining()];
            input.get(reference).rewind();
        }

        void run(int blocks, boolean measured, BlockWindow timings) {
            for (int block = 0; block < blocks; block++, sequence++) {
                if (scenario.curves.length > 1 && sequence % 8 == 0) {
                    configuration.configure(scenario.enabled,
                            scenario.curves[(int)((sequence / 8) % scenario.curves.length)]);
                }
                input.rewind();
                long started = measured ? System.nanoTime() : 0;
                processor.queueInput(input);
                last = processor.getOutput();
                if (measured) timings.values[timings.start + block] = System.nanoTime() - started;
                if (last.remaining() != reference.length) throw new AssertionError("Frame count changed");
                // Absolute reads leave the output window intact. This small
                // fixed consumer is included in throughput CPU measurements.
                checksum = checksum * 31 + last.getInt(0);
                checksum = checksum * 31 + last.getInt(last.limit() / 2 / 4 * 4);
                checksum = checksum * 31 + last.getInt(last.limit() - 4);
            }
            consumed ^= checksum;
        }

        void verifyLastOutput() {
            boolean shouldBypass = !scenario.enabled;
            if (scenario.curves.length == 1 && Arrays.equals(scenario.curves[0], new double[10])) {
                shouldBypass = true;
            }
            bypassExact = true;
            for (int index = 0; index < reference.length; index++) {
                if (last.get(index) != reference[index]) bypassExact = false;
            }
            if (shouldBypass && !bypassExact) throw new AssertionError("Bypass changed PCM bytes");
            ByteBuffer view = last.duplicate().order(ByteOrder.LITTLE_ENDIAN);
            while (view.hasRemaining()) {
                double sample = encoding == C.ENCODING_PCM_FLOAT ? view.getFloat() : view.getShort() / 32768.0;
                if (!Double.isFinite(sample)) throw new AssertionError("Non-finite PCM output");
                lastPeak = Math.max(lastPeak, Math.abs(sample));
            }
            if (lastPeak > 1.000001) throw new AssertionError("Out-of-range PCM output");
        }

        void close() { processor.reset(); }
    }

    private static List<Scenario> scenarios(JSONObject presets) throws Exception {
        List<Scenario> result = new ArrayList<>();
        result.add(new Scenario("disabled", false, filled(6)));
        result.add(new Scenario("flat", true, new double[10]));
        for (int band = 0; band < 10; band++) {
            for (int sign : new int[] {1, -1}) {
                double[] curve = new double[10];
                curve[band] = 6 * sign;
                result.add(new Scenario("band_" + (int)BStreamEqualizerConfiguration.FREQUENCIES[band]
                        + (sign > 0 ? "_plus6" : "_minus6"), true, curve));
            }
        }
        result.add(new Scenario("all_plus6", true, filled(6)));
        result.add(new Scenario("all_plus12", true, filled(12)));
        result.add(new Scenario("all_minus6", true, filled(-6)));
        double[] alternating = new double[10];
        for (int band = 0; band < 10; band++) alternating[band] = band % 2 == 0 ? 12 : -12;
        result.add(new Scenario("alternating12", true, alternating));
        List<double[]> presetCurves = new ArrayList<>();
        Iterator<String> keys = presets.keys();
        while (keys.hasNext()) {
            String name = keys.next();
            if (name.equals("custom")) continue;
            JSONArray raw = presets.getJSONArray(name);
            if (raw.length() != 10) throw new IllegalArgumentException("Preset must have ten gains: " + name);
            double[] curve = new double[10];
            for (int index = 0; index < 10; index++) curve[index] = raw.getDouble(index);
            result.add(new Scenario("preset_" + name, true, curve));
            presetCurves.add(curve);
        }
        result.add(new Scenario("transitions_presets_80ms", true, presetCurves.toArray(new double[0][])));
        double[][] moving = new double[49][10];
        for (int step = 0; step < moving.length; step++) {
            for (int band = 0; band < 10; band++) moving[step][band] = (step / 2.0 - 12) * (band % 2 == 0 ? 1 : -1);
        }
        result.add(new Scenario("transitions_all_bands_80ms", true, moving));
        return result;
    }

    private static double[] filled(double gain) {
        double[] values = new double[10];
        Arrays.fill(values, gain);
        return values;
    }

    private static long runtimeStat(String key) {
        try { return Long.parseLong(Debug.getRuntimeStat(key)); }
        catch (Exception ignored) { return -1; }
    }

    private static double percentile(double[] source, double fraction) {
        double[] sorted = source.clone();
        Arrays.sort(sorted);
        return sorted[Math.max(0, Math.min(sorted.length - 1, (int)Math.ceil(sorted.length * fraction) - 1))];
    }

    private static double percentile(long[] source, double fraction) {
        long[] sorted = source.clone();
        Arrays.sort(sorted);
        return sorted[Math.max(0, Math.min(sorted.length - 1, (int)Math.ceil(sorted.length * fraction) - 1))];
    }

    private static JSONObject readJson(String path) throws Exception {
        try (FileInputStream input = new FileInputStream(path);
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] block = new byte[4096];
            int count;
            while ((count = input.read(block)) >= 0) bytes.write(block, 0, count);
            return new JSONObject(bytes.toString(StandardCharsets.UTF_8.name()));
        }
    }
}
