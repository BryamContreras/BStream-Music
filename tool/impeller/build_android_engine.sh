#!/usr/bin/env bash
# Build a mode-matched arm64 engine from the exact pinned Flutter source.
set -euo pipefail
if [[ $# != 3 || ( "$1" != profile && "$1" != release ) ]]; then
  echo "Usage: $0 <profile|release> <isolated Flutter 3.47.9 checkout> <output libflutter.so>" >&2
  exit 2
fi
mode="$1"
checkout="$(realpath "$2")"
output="$(realpath -m "$3")"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch="$dir/downsample-scissor.patch"
revision=c197ca5199e9ee5661e865596c9c07294dfab51c
test "$(git -C "$checkout" rev-parse HEAD)" = "$revision" || {
  echo "Expected Flutter framework revision $revision." >&2; exit 1;
}
if git -C "$checkout" apply --check "$patch" 2>/dev/null; then
  git -C "$checkout" diff --quiet || {
    echo "The isolated engine checkout contains unrelated tracked edits." >&2; exit 1;
  }
  git -C "$checkout" apply "$patch"
elif git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null; then
  git -C "$checkout" diff --no-ext-diff --binary | cmp -s - "$patch" || {
    echo "The isolated checkout has edits beyond the exact native patch." >&2; exit 1;
  }
  echo "The native patch is already applied."
else
  echo "The isolated checkout is not in a compatible patch state." >&2
  exit 1
fi
git -C "$checkout" diff --check
depot_tools="${BSTREAM_DEPOT_TOOLS:-$(dirname "$checkout")/depot_tools}"
if [[ -d "$depot_tools" ]]; then export PATH="$depot_tools:$PATH"; fi
command -v vpython3 >/dev/null || {
  echo "depot_tools must be on PATH or specified in BSTREAM_DEPOT_TOOLS." >&2; exit 1;
}
export DEPOT_TOOLS_UPDATE=0
export NINJA_STATUS='[%f/%t %e s] '
cd "$checkout/engine/src"
target="bstream_android_${mode}_arm64"
flutter/tools/gn --target-dir "$target" --runtime-mode "$mode" --android --android-cpu arm64 --no-rbe --no-goma
ninja_bin="${BSTREAM_NINJA_BIN:-/usr/bin/ninja}"
if [[ ! -x "$ninja_bin" ]]; then ninja_bin="$(command -v ninja)"; fi
out="out/$target"
"$ninja_bin" -C "$out" -j "${BSTREAM_ENGINE_JOBS:-12}" flutter/shell/platform/android:flutter_shell_native
mkdir -p "$(dirname "$output")"
cp "$out/lib.stripped/libflutter.so" "$output"
sha256sum "$output"
python3 - "$output" "$patch" "$mode" "$revision" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
library, patch = map(Path, sys.argv[1:3])
mode, revision = sys.argv[3:]
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
library.with_suffix(library.suffix + ".json").write_text(json.dumps({
    "mode": mode, "abi": "arm64-v8a", "frameworkRevision": revision,
    "engineRevision": "89c39edfdfae2949f6806e4a315c0c08522238b7",
    "patchSha256": digest(patch), "librarySha256": digest(library),
}, indent=2) + "\n", encoding="utf-8")
PY
