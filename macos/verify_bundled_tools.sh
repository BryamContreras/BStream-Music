#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo \
    "Usage: $0 <app-bundle> <expected-architecture> <expected-yt-dlp-sha256>" \
    >&2
  exit 64
fi

app_bundle="$1"
expected_arch="$2"
expected_yt_dlp_sha256="$3"
tools_dir="$app_bundle/Contents/Resources/tools"
yt_dlp="$tools_dir/yt-dlp"
deno="$tools_dir/deno"
smoke_tmp=""

cleanup() {
  if [[ -n "$smoke_tmp" ]]; then
    /bin/rm -rf "$smoke_tmp"
  fi
}

trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 69
fi

test -x "$yt_dlp"
test -x "$deno"

unexpected_media_tool="$(
  find "$tools_dir" -mindepth 1 \
    \( -iname 'ffmpeg*' -o -iname 'ffprobe*' \) \
    -print -quit
)"
if [[ -n "$unexpected_media_tool" ]]; then
  echo "Unexpected external media tool in app bundle: $unexpected_media_tool" >&2
  exit 1
fi

actual_yt_dlp_sha256="$(
  /usr/bin/shasum -a 256 "$yt_dlp" | /usr/bin/awk '{ print $1 }'
)"
if [[ "$actual_yt_dlp_sha256" != "$expected_yt_dlp_sha256" ]]; then
  echo "The bundled yt-dlp executable was modified after verification." >&2
  echo "Expected: $expected_yt_dlp_sha256" >&2
  echo "Actual:   $actual_yt_dlp_sha256" >&2
  exit 1
fi

/usr/bin/lipo "$yt_dlp" -verify_arch "$expected_arch"
/usr/bin/lipo "$deno" -verify_arch "$expected_arch"
/usr/bin/codesign --verify --strict --verbose=2 "$yt_dlp"
/usr/bin/codesign --verify --strict --verbose=2 "$deno"

deno_entitlements="$(
  /usr/bin/codesign -d --entitlements :- "$deno" 2>/dev/null
)"
if ! /usr/bin/grep -Fq "com.apple.security.cs.allow-jit" \
  <<<"$deno_entitlements"; then
  echo "The bundled Deno executable is missing its JIT entitlement." >&2
  exit 1
fi

# Executing the onefile binary is essential: codesign can validate its outer
# launcher while an incompatible embedded Python still fails after extraction.
smoke_tmp="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/bstream-ytdlp.XXXXXX")"
if ! yt_dlp_version="$(
  TMPDIR="$smoke_tmp" "$yt_dlp" --ignore-config --version 2>&1
)"; then
  echo "$yt_dlp_version" >&2
  echo "The bundled yt-dlp executable could not start." >&2
  exit 1
fi

if [[ -z "$yt_dlp_version" ]]; then
  echo "The bundled yt-dlp executable returned an empty version." >&2
  exit 1
fi

if ! deno_version="$("$deno" --version 2>&1)"; then
  echo "$deno_version" >&2
  echo "The bundled Deno executable could not start." >&2
  exit 1
fi

if [[ "$deno_version" != deno\ * ]]; then
  echo "The bundled Deno executable returned unexpected output." >&2
  echo "$deno_version" >&2
  exit 1
fi

if ! "$deno" eval \
  'let total = 0; for (let index = 0; index < 100000; index++) total += index; if (total !== 4999950000) Deno.exit(1);'; then
  echo "The bundled Deno executable could not execute JavaScript." >&2
  exit 1
fi

# Ensure yt-dlp accepts the exact runtime path used by the application. A
# YouTube request is intentionally avoided here so packaging verification does
# not depend on third-party network availability.
if ! runtime_smoke="$(
  TMPDIR="$smoke_tmp" "$yt_dlp" \
    --ignore-config \
    --js-runtimes "deno:$deno" \
    --js-runtimes node \
    --version \
    2>&1
)"; then
  echo "$runtime_smoke" >&2
  echo "yt-dlp rejected the bundled JavaScript runtime configuration." >&2
  exit 1
fi

echo "yt-dlp $yt_dlp_version"
echo "${deno_version%%$'\n'*}"
