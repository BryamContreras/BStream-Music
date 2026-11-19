"""Validate and compare native EQ benchmark JSONL files (Python stdlib only).

Run from the repository root, after before/after runs use the SAME preset bank:

  python tool/benchmarks/summarize_equalizer_benchmarks.py \
    --android-after .dart_tool/eq-bench-android/optimized/results.jsonl \
    --c-after .dart_tool/eq-c-optimized.jsonl \
    --windows .dart_tool/eq-windows-process.json \
    --c-host "Android emulator x86_64; NDK optimized C binary"

The output keeps Android callback percentiles, C batch percentiles and Windows
whole-process CPU in separate fields. None represents a battery measurement.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import statistics
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
FREQUENCIES = (31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000)
PRESETS = (
    "flat", "acoustic", "bassBoost", "bassCut", "vocal", "trebleBoost",
    "trebleCut", "loudness", "spokenWord", "electronic", "rock", "hipHop",
    "jazz", "classical", "smallSpeakers", "lateNight",
)
CaseKey = tuple[int, int, str, str]


class InvalidBenchmark(ValueError):
    """The supplied measurements cannot support a valid before/after result."""


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    # Windows PowerShell redirection emits UTF-16; the ART runner uses UTF-8.
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return raw.decode(encoding)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows = []
    for line_number, line in enumerate(read_text(path).splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise InvalidBenchmark(f"{path}:{line_number}: invalid JSON: {error}") from error
        if not isinstance(row, dict):
            raise InvalidBenchmark(f"{path}:{line_number}: expected an object")
        rows.append(row)
    if not rows:
        raise InvalidBenchmark(f"{path}: no measurements")
    return rows


def finite_number(value: Any, description: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise InvalidBenchmark(f"{description}: expected a number, got {value!r}")
    result = float(value)
    if not math.isfinite(result) or result < 0 or (positive and result == 0):
        raise InvalidBenchmark(f"{description}: invalid value {value!r}")
    return result


def integer(value: Any, description: str, *, positive: bool = False) -> int:
    numeric = finite_number(value, description, positive=positive)
    if numeric != math.floor(numeric):
        raise InvalidBenchmark(f"{description}: expected an integer")
    return int(numeric)


def hex_checksum(value: Any, description: str) -> str:
    if isinstance(value, int) and not isinstance(value, bool):
        if value < -(1 << 63) or value >= (1 << 64):
            raise InvalidBenchmark(f"{description}: checksum is outside 64-bit range")
        return f"{value & ((1 << 64) - 1):016x}"
    if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{16}", value):
        return value.lower()
    raise InvalidBenchmark(f"{description}: malformed 64-bit checksum")


def source_description(path: Path, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    try:
        display_path = path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        display_path = str(path)
    result: dict[str, Any] = {
        "path": display_path,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    if metadata is not None:
        result["metadata"] = metadata
    return result


def canonical_c_name(name: str) -> str:
    if name == "off":
        return "disabled"
    band = re.fullmatch(r"band_(\d+)_(plus6|minus6)", name)
    if band:
        index = int(band.group(1))
        if index >= len(FREQUENCIES):
            raise InvalidBenchmark(f"C benchmark has unknown band index {index}")
        return f"band_{FREQUENCIES[index]}_{band.group(2)}"
    if name in PRESETS and name != "flat":
        return f"preset_{name}"
    if name == "all_plus6_transition":
        # This is one initial 25 ms ramp, NOT Android's repeated 80 ms changes.
        return "initial_all_plus6_transition"
    return name


def normalize_case(row: dict[str, Any], engine: str) -> tuple[CaseKey, dict[str, Any]]:
    android = engine == "androidArt"
    rate = integer(row.get("sampleRate" if android else "rate"), "sample rate", positive=True)
    channels = integer(row.get("channels"), "channels", positive=True)
    pcm = row.get("pcm" if android else "format")
    pcm = "float32" if pcm == "f32" else pcm
    if pcm not in ("float32", "s16"):
        raise InvalidBenchmark(f"Unknown PCM format: {pcm!r}")
    raw_name = row.get("scenario" if android else "case")
    if not isinstance(raw_name, str) or not raw_name:
        raise InvalidBenchmark("Missing scenario name")
    name = raw_name if android else canonical_c_name(raw_name)
    result: dict[str, Any] = {
        "scenario": name,
        "sampleRate": rate,
        "channels": channels,
        "pcm": pcm,
        "repetitions": integer(row.get("repetitions"), "repetitions", positive=True),
        "cpuMsPerAudioSecond": finite_number(
            row.get("medianCpuMsPerAudioSecond" if android else "cpu_ms_per_audio_second_median"),
            f"{name} median CPU ms/audio second", positive=True,
        ),
        "p95RepetitionCpuMsPerAudioSecond": finite_number(
            row.get("p95CpuMsPerAudioSecond" if android else "cpu_ms_per_audio_second_p95"),
            f"{name} p95 repetition CPU ms/audio second", positive=True,
        ),
        "outputChecksum": hex_checksum(
            row.get("checksum" if android else "output_hash"), f"{name} output hash",
        ),
        "bypassByteExact": row.get("bypassExact" if android else "bypass_byte_exact"),
    }
    result["equivalentSingleThreadCorePercent"] = result["cpuMsPerAudioSecond"] / 10
    if android:
        result.update({
            "audioSecondsPerRepetition": finite_number(row.get("audioSecondsPerRepetition"), "audio seconds", positive=True),
            "individualCallbackP95WallUs": finite_number(row.get("p95BlockWallUs"), "callback p95"),
            "individualCallbackMaxWallUs": finite_number(row.get("maxBlockWallUs"), "callback maximum"),
            "callbacksAtOrAbove10ms": integer(row.get("blocksAtOrAbove10ms"), "missed deadlines"),
            "measuredCallbacks": integer(row.get("measuredBlocks"), "measured callbacks", positive=True),
            "gcCollections": integer(row.get("gcCollectionsDuringMeasurement"), "GC collections"),
            "allocatedBytes": integer(row.get("allocatedBytesDuringMeasurement"), "allocated bytes"),
        })
        supplied_percent = finite_number(row.get("equivalentSingleCorePercent"), "single core percent")
        if not math.isclose(supplied_percent, result["cpuMsPerAudioSecond"] / 10, rel_tol=1e-6, abs_tol=1e-9):
            raise InvalidBenchmark(f"{name}: inconsistent CPU unit conversion")
        peak = finite_number(row.get("lastOutputPeak"), "output peak")
        if peak > 1.000001:
            raise InvalidBenchmark(f"{name}: invalid bounded output peak {peak}")
    else:
        result.update({
            "framesPerBlock": integer(row.get("frames_per_block"), "frames/block", positive=True),
            "blocksPerRepetition": integer(row.get("blocks_per_repetition"), "blocks/repetition", positive=True),
            "batchMeanPerBlockP95WallUs": finite_number(row.get("wall_us_per_block_batch_p95"), "C batch p95"),
            "configureCpuUs": finite_number(row.get("configure_cpu_us_median"), "configuration median"),
            "configureP95CpuUs": finite_number(row.get("configure_cpu_us_p95"), "configuration p95"),
        })
    if name in ("disabled", "flat", "preset_flat") and result["bypassByteExact"] is not True:
        raise InvalidBenchmark(f"{name}: bypass did not preserve input bytes")
    return (rate, channels, pcm, name), result


def load_run(path: Path, engine: str) -> tuple[dict[CaseKey, dict[str, Any]], dict[str, Any]]:
    raw_rows = read_jsonl(path)
    metadata: dict[str, Any] = {}
    if engine == "androidArt":
        if any(row.get("type") not in ("metadata", "case", "complete") for row in raw_rows):
            raise InvalidBenchmark(f"{path}: unexpected Android record type")
        starts = [row for row in raw_rows if row.get("type") == "metadata"]
        finishes = [row for row in raw_rows if row.get("type") == "complete"]
        if len(starts) != 1 or len(finishes) != 1 or raw_rows[-1].get("type") != "complete":
            raise InvalidBenchmark(f"{path}: Android run has no unique metadata/completion record")
        metadata = dict(starts[0])
        metadata["completionChecksum"] = hex_checksum(finishes[0].get("checksum"), "completion checksum")
        raw_rows = [row for row in raw_rows if row.get("type") == "case"]
    elif any(row.get("engine") != "portable-c" for row in raw_rows):
        raise InvalidBenchmark(f"{path}: unexpected portable-C engine record")
    indexed = {}
    for row in raw_rows:
        key, normalized = normalize_case(row, engine)
        if engine == "portableC" and key in indexed and key[3] == "flat":
            # The C harness emits its built-in flat case and the exported flat
            # preset under the same raw name, in that order. Keep both samples.
            key = (*key[:3], "preset_flat")
            normalized["scenario"] = "preset_flat"
        if key in indexed:
            raise InvalidBenchmark(f"{path}: duplicate case {key}")
        indexed[key] = normalized
    groups: dict[tuple[int, int, str], set[str]] = defaultdict(set)
    for rate, channels, pcm, name in indexed:
        groups[rate, channels, pcm].add(name)
    if set((rate, pcm) for rate, _, pcm in groups) != {
        (rate, pcm) for rate in (48000, 96000) for pcm in ("s16", "float32")
    }:
        raise InvalidBenchmark(f"{path}: expected both 48/96 kHz and s16/float32 groups")
    required = {"disabled", "flat", "all_plus6", "all_minus6", "alternating12"}
    required.update(f"band_{hz}_{direction}" for hz in FREQUENCIES for direction in ("plus6", "minus6"))
    required.update(f"preset_{name}" for name in PRESETS)
    for group, names in groups.items():
        if missing := required - names:
            raise InvalidBenchmark(f"{path}: group {group} is missing {sorted(missing)}")
        if engine == "androidArt" and len(names) != metadata.get("scenarioCount"):
            raise InvalidBenchmark(f"{path}: scenario count disagrees with Android metadata")
    return indexed, metadata


def reduction(before: float, after: float) -> float:
    return (before - after) / before * 100


def family(name: str) -> str:
    if name in ("disabled", "flat", "preset_flat"):
        return "bypass"
    if name.startswith("band_"):
        return "singleBand"
    if name.startswith("preset_"):
        return "presets"
    if name.startswith(("transitions_", "initial_")):
        return "configurationChanges"
    return "combinedBands"


def median_range(values: list[float]) -> dict[str, float]:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def compare_runs(before_path: Path, after_path: Path, engine: str) -> dict[str, Any]:
    before, before_metadata = load_run(before_path, engine)
    after, after_metadata = load_run(after_path, engine)
    if before.keys() != after.keys():
        missing = sorted(before.keys() - after.keys())
        extra = sorted(after.keys() - before.keys())
        raise InvalidBenchmark(f"{engine}: cases differ; missing={missing}, extra={extra}")
    if engine == "androidArt":
        for key in ("runtime", "model", "abi", "sdk", "repetitions", "audioSecondsPerRepetition", "blockDurationMs", "channels", "scenarioCount"):
            if before_metadata.get(key) != after_metadata.get(key):
                raise InvalidBenchmark(f"{engine}: metadata {key} differs between runs")
        if before_metadata["completionChecksum"] != after_metadata["completionChecksum"]:
            raise InvalidBenchmark("Android aggregate completion checksums differ")
    comparisons = []
    grouped: dict[tuple[int, int, str, str], list[dict[str, Any]]] = defaultdict(list)
    for key in sorted(before):
        initial, optimized = before[key], after[key]
        if initial["outputChecksum"] != optimized["outputChecksum"]:
            raise InvalidBenchmark(f"{engine}: output checksum differs for {key}")
        settings = ("repetitions", "audioSecondsPerRepetition", "framesPerBlock", "blocksPerRepetition", "measuredCallbacks")
        for setting in settings:
            if initial.get(setting) != optimized.get(setting):
                raise InvalidBenchmark(f"{engine}: {setting} differs for {key}")
        comparison = {
            "scenario": key[3], "sampleRate": key[0], "channels": key[1], "pcm": key[2],
            "family": family(key[3]), "before": initial, "after": optimized,
            "cpuReductionPercent": reduction(initial["cpuMsPerAudioSecond"], optimized["cpuMsPerAudioSecond"]),
            "identicalOutputChecksum": True,
        }
        comparisons.append(comparison)
        grouped[key[0], key[1], key[2], family(key[3])].append(comparison)
    summaries = []
    for (rate, channels, pcm, category), rows in sorted(grouped.items()):
        summary: dict[str, Any] = {
            "sampleRate": rate, "channels": channels, "pcm": pcm, "family": category,
            "scenarioCount": len(rows),
            "beforeCpuMsPerAudioSecondAcrossScenarios": median_range([row["before"]["cpuMsPerAudioSecond"] for row in rows]),
            "afterCpuMsPerAudioSecondAcrossScenarios": median_range([row["after"]["cpuMsPerAudioSecond"] for row in rows]),
            "cpuReductionPercentAcrossScenarios": median_range([row["cpuReductionPercent"] for row in rows]),
        }
        if engine == "androidArt":
            for phase in ("before", "after"):
                summary[f"{phase}IndividualCallbackP95WallUsAcrossScenarios"] = median_range([row[phase]["individualCallbackP95WallUs"] for row in rows])
                summary[f"{phase}CallbacksAtOrAbove10ms"] = sum(row[phase]["callbacksAtOrAbove10ms"] for row in rows)
                summary[f"{phase}GcCollections"] = sum(row[phase]["gcCollections"] for row in rows)
                summary[f"{phase}AllocatedBytes"] = sum(row[phase]["allocatedBytes"] for row in rows)
        else:
            for phase in ("before", "after"):
                summary[f"{phase}BatchMeanPerBlockP95WallUsAcrossScenarios"] = median_range([row[phase]["batchMeanPerBlockP95WallUs"] for row in rows])
                summary[f"{phase}ConfigureCpuUsAcrossScenarios"] = median_range([row[phase]["configureCpuUs"] for row in rows])
        summaries.append(summary)
    return {
        "sourceFiles": {"before": source_description(before_path, before_metadata), "after": source_description(after_path, after_metadata)},
        "integrity": {"matchingCases": len(comparisons), "allOutputChecksumsIdentical": True, "bypassByteExact": True},
        "groups": summaries,
        "cases": comparisons,
    }


def summarize_windows(path: Path) -> dict[str, Any]:
    source = json.loads(read_text(path))
    if not isinstance(source, dict) or not isinstance(source.get("rows"), list):
        raise InvalidBenchmark(f"{path}: expected Windows object with rows")
    grouped: dict[tuple[int, int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in source["rows"]:
        key = (integer(row.get("sample_rate"), "Windows rate", positive=True), integer(row.get("channels"), "Windows channels", positive=True), str(row.get("case")))
        for name in ("process_cpu_us", "wall_us", "played_us", "cpu_percent_one_core", "configure_us"):
            finite_number(row.get(name), f"Windows {name}", positive=name in ("wall_us", "played_us"))
        if not math.isclose(row["cpu_percent_one_core"], 100 * row["process_cpu_us"] / row["wall_us"], rel_tol=1e-6, abs_tol=1e-9):
            raise InvalidBenchmark(f"{path}: inconsistent Windows CPU unit conversion")
        grouped[key].append(row)
    if not grouped:
        raise InvalidBenchmark(f"{path}: no Windows measurements")
    summaries = []
    required_cases = {"off", "flat", "one_band", "bass_boost", "all_boost", "alternating"}
    if set((rate, name) for rate, _, name in grouped) != {
        (rate, name) for rate in (48000, 96000) for name in required_cases
    }:
        raise InvalidBenchmark(f"{path}: Windows scenario/rate coverage is incomplete")
    for (rate, channels, name), rows in sorted(grouped.items()):
        repeats = [row.get("repeat") for row in rows]
        if len(repeats) != len(set(repeats)):
            raise InvalidBenchmark(f"{path}: repeated Windows repetition for {rate}/{name}")
        if len(rows) < 3:
            raise InvalidBenchmark(f"{path}: fewer than three Windows repetitions for {rate}/{name}")
        summaries.append({
            "sampleRate": rate, "channels": channels, "scenario": name, "repetitions": len(rows),
            "wholeProcessSingleCorePercent": median_range([row["cpu_percent_one_core"] for row in rows]),
            "configurationMs": median_range([row["configure_us"] / 1000 for row in rows]),
            "playedSeconds": median_range([row["played_us"] / 1e6 for row in rows]),
        })
    return {
        "sourceFile": source_description(path, {key: value for key, value in source.items() if key != "rows"}),
        "measurement": "Whole profile process with null audio output, without the music UI; not battery or complete interactive-app consumption.",
        "groups": summaries,
        "rows": source["rows"],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--android-before", type=Path, default=Path(".dart_tool/eq-bench-android/baseline/results.jsonl"))
    parser.add_argument("--android-after", type=Path, required=True)
    parser.add_argument("--c-before", type=Path, default=Path(".dart_tool/eq-c-baseline.jsonl"))
    parser.add_argument("--c-after", type=Path, required=True)
    parser.add_argument("--windows", type=Path)
    parser.add_argument("--c-host", default="Execution host not recorded in raw C JSONL; do not interpret this as an iOS-device measurement.")
    parser.add_argument("--output", type=Path, default=Path("docs/benchmarks/equalizer-results.json"))
    args = parser.parse_args()
    try:
        android = compare_runs(args.android_before, args.android_after, "androidArt")
        portable_c = compare_runs(args.c_before, args.c_after, "portableC")
        portable_c["executionHost"] = args.c_host
        report: dict[str, Any] = {
            "schemaVersion": 1,
            "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
            "presetBank": "Both optimization baseline and after use the same newly tuned ten-band preset bank. Preset retuning is not counted as a CPU optimization.",
            "limits": [
                "Native microbenchmarks measure processing throughput, not whole-app battery or device energy.",
                "Android ART runs the production Media3 processor on the recorded emulator/device. A desktop host or emulator is not representative of every physical phone.",
                "Portable C exercises the iOS DSP source on the stated host; it is not an AVAudioProcessingTap or physical iPhone energy measurement.",
                "Android individual-callback p95 and portable-C batch-mean p95 use different sampling and must not be compared as equivalent latency distributions.",
                "CPU ms/audio second divided by ten gives an equivalent single-thread core percentage; it is not a sampled process CPU percentage.",
                "Per-scenario checksums compare the same engine and input before/after. Inputs and harness overhead differ across engines; cross-engine checksums and CPU ratios are not comparable.",
                "Android's checksum consumes three output words per block; portable C hashes the complete measured buffers. These checks guard regressions and are not a formal proof for every possible input.",
                "Android GC/allocation counters describe the ART runtime during the measurement window, including instrumentation or JIT activity; they are not allocation attribution to one DSP function.",
                "Windows 3-second whole-process windows can be noisy and timer-quantized at low CPU use. Their before/after-free scenario differences do not isolate the equalizer's incremental CPU cost.",
            ],
            "engines": {"androidArt": android, "portableC": portable_c},
        }
        if args.windows:
            report["engines"]["windowsProcess"] = summarize_windows(args.windows)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    except (OSError, UnicodeError, json.JSONDecodeError, InvalidBenchmark) as error:
        print(f"Cannot summarize equalizer measurements: {error}", file=sys.stderr)
        return 1
    print(f"Validated {android['integrity']['matchingCases']} Android and {portable_c['integrity']['matchingCases']} portable-C cases; output checksums match.")
    print(f"Wrote {args.output}")
    for name in ("androidArt", "portableC"):
        for group in report["engines"][name]["groups"]:
            before = group["beforeCpuMsPerAudioSecondAcrossScenarios"]["median"]
            after = group["afterCpuMsPerAudioSecondAcrossScenarios"]["median"]
            saved = group["cpuReductionPercentAcrossScenarios"]["median"]
            print(f"{name:11} {group['sampleRate']:5} {group['pcm']:7} {group['family']:20} {before:9.4f} -> {after:9.4f} ms/audio-s; median reduction {saved:+.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
