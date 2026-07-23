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
ffmpeg="$tools_dir/ffmpeg"
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
test -x "$ffmpeg"

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
/usr/bin/lipo "$ffmpeg" -verify_arch "$expected_arch"
/usr/bin/codesign --verify --strict --verbose=2 "$yt_dlp"
/usr/bin/codesign --verify --strict --verbose=2 "$ffmpeg"

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

if ! ffmpeg_version="$("$ffmpeg" -version 2>&1)"; then
  echo "$ffmpeg_version" >&2
  echo "The bundled FFmpeg executable could not start." >&2
  exit 1
fi

if [[ "$ffmpeg_version" != ffmpeg\ version* ]]; then
  echo "The bundled FFmpeg executable returned unexpected output." >&2
  echo "$ffmpeg_version" >&2
  exit 1
fi

echo "yt-dlp $yt_dlp_version"
echo "${ffmpeg_version%%$'\n'*}"
