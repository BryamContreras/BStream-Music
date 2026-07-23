#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-bundle> [signing-identity] [entitlements]" >&2
  exit 64
fi

app_bundle="$1"
signing_identity="${2:--}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
entitlements="${3:-$script_dir/Runner/Release.entitlements}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 69
fi

if [[ ! -d "$app_bundle/Contents" ]]; then
  echo "Invalid macOS app bundle: $app_bundle" >&2
  exit 66
fi

if [[ ! -f "$entitlements" ]]; then
  echo "Missing entitlements file: $entitlements" >&2
  exit 66
fi

timestamp_args=(--timestamp)
if [[ "$signing_identity" == "-" ]]; then
  timestamp_args=(--timestamp=none)
fi

preserved_yt_dlp="$app_bundle/Contents/Resources/tools/yt-dlp"

sign_macho_files() {
  local root="$1"

  [[ -d "$root" ]] || return 0

  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q "Mach-O"; then
      # yt-dlp_macos is a PyInstaller onefile executable. Its Python runtime
      # lives inside the executable archive, so post-signing only the launcher
      # with Hardened Runtime makes the extracted Python fail Team ID library
      # validation. Preserve and validate the complete upstream executable.
      if [[ "$candidate" == "$preserved_yt_dlp" ]]; then
        /usr/bin/codesign --verify --strict --verbose=2 "$candidate"
        continue
      fi

      /usr/bin/codesign \
        --force \
        --options runtime \
        --sign "$signing_identity" \
        "${timestamp_args[@]}" \
        "$candidate"
    fi
  done < <(/usr/bin/find "$root" -type f -print0)
}

# Sign every executable image before its containing bundle. This replaces
# signatures inherited from third-party framework vendors with the same
# identity used for BStream Music.
sign_macho_files "$app_bundle/Contents/Frameworks"
sign_macho_files "$app_bundle/Contents/PlugIns"
sign_macho_files "$app_bundle/Contents/XPCServices"
sign_macho_files "$app_bundle/Contents/Resources/tools"

while IFS= read -r -d '' nested_bundle; do
  /usr/bin/codesign \
    --force \
    --options runtime \
    --sign "$signing_identity" \
    "${timestamp_args[@]}" \
    "$nested_bundle"
done < <(
  /usr/bin/find "$app_bundle/Contents" -depth -type d \
    \( -name "*.framework" -o -name "*.appex" -o -name "*.xpc" -o -name "*.bundle" \) \
    -print0
)

# The outer application must always be signed last because its resource seal
# records the signatures of all nested code.
/usr/bin/codesign \
  --force \
  --options runtime \
  --entitlements "$entitlements" \
  --sign "$signing_identity" \
  "${timestamp_args[@]}" \
  "$app_bundle"

/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_bundle"
