#!/usr/bin/env bash
# Exercise the exact helper implementation with Impeller's real Matrix/Rect.
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: $0 <isolated Flutter 3.47.9 checkout>" >&2
  exit 2
fi
checkout="$(realpath "$1")"
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$checkout/engine/src"
test "$(git -C "$checkout" rev-parse HEAD)" = c197ca5199e9ee5661e865596c9c07294dfab51c
temp="$(mktemp -d)"
trap 'rm -f "$temp/geometry.cc" "$temp/geometry"; rmdir "$temp"' EXIT
python3 - "$dir" "$temp" <<'PY'
import sys
from pathlib import Path
root, temp = map(Path, sys.argv[1:])
lines=(root/"downsample-scissor.patch").read_text().splitlines()
start=next(i for i,s in enumerate(lines) if s.startswith("+std::optional<IRect32> GaussianBlurFilterContents::CalculateDownsampleScissor("))
end=next(i for i in range(start,len(lines)) if lines[i]=="+}")
impl="\n".join(s[1:] for s in lines[start:end+1]).replace("GaussianBlurFilterContents::CalculateDownsampleScissor","CalculateDownsampleScissor")
body=(root/"geometry_native_test.cc").read_text()
(temp/"geometry.cc").write_text(body.replace("// EXACT_ENGINE_IMPL",impl))
PY
clang++ -std=c++20 -DNDEBUG -O2 -ffunction-sections -fdata-sections \
  -I"$work" -I"$work/flutter" "$temp/geometry.cc" \
  "$work/flutter/impeller/geometry/matrix.cc" \
  -Wl,--gc-sections -o "$temp/geometry"
"$temp/geometry"
