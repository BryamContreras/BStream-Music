#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <app-bundle> <expected-architecture> <expected-version>" >&2
  exit 64
fi

app_bundle="$1"
expected_arch="$2"
expected_version="$3"
info_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/bstream_music"
frameworks_dir="$app_bundle/Contents/Frameworks"
failures=0
macho_count=0

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 69
fi

test -d "$app_bundle"
test -x "$executable"
/usr/bin/plutil -lint "$info_plist"

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

test "$(read_plist CFBundleIdentifier)" = "com.bstream.bstreamMusic"
test "$(read_plist CFBundleExecutable)" = "bstream_music"
test "$(read_plist CFBundlePackageType)" = "APPL"
test "$(read_plist CFBundleShortVersionString)" = "$expected_version"

while IFS= read -r -d '' candidate; do
  description="$(/usr/bin/file -b "$candidate")"
  [[ "$description" == *Mach-O* ]] || continue
  macho_count=$((macho_count + 1))

  if ! /usr/bin/lipo "$candidate" -verify_arch "$expected_arch" >/dev/null 2>&1; then
    echo "Missing $expected_arch architecture: $candidate" >&2
    failures=1
  fi

  if ! /usr/bin/codesign --verify --strict "$candidate" >/dev/null 2>&1; then
    echo "Invalid code signature: $candidate" >&2
    failures=1
  fi

  if ! dependencies="$(/usr/bin/otool -L "$candidate" 2>&1)"; then
    echo "Cannot inspect dynamic dependencies: $candidate" >&2
    failures=1
    continue
  fi

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue

    # For a dynamic library, otool includes LC_ID_DYLIB before its actual
    # dependencies. Some vendored frameworks retain their build-time absolute
    # path there; it identifies the current file and is never loaded by dyld.
    [[ "$dependency" == "$candidate" ]] && continue

    case "$dependency" in
      @rpath/*)
        relative_path="${dependency#@rpath/}"
        if [[ ! -e "$frameworks_dir/$relative_path" ]]; then
          echo "Unresolved @rpath dependency in $candidate: $dependency" >&2
          failures=1
        fi
        ;;
      @loader_path/*|@executable_path/*|/System/Library/*|/usr/lib/*)
        ;;
      *)
        echo "Non-portable dependency in $candidate: $dependency" >&2
        failures=1
        ;;
    esac
  done < <(/usr/bin/awk 'NR > 1 { print $1 }' <<<"$dependencies")
done < <(/usr/bin/find "$app_bundle/Contents" -type f -print0)

if ((macho_count == 0)); then
  echo "No Mach-O files found in $app_bundle." >&2
  exit 1
fi

entitlements="$(/usr/bin/codesign -d --entitlements :- "$app_bundle" 2>/dev/null)"
if ! /usr/bin/grep -Fq "com.apple.security.cs.disable-library-validation" <<<"$entitlements"; then
  echo "Release bundle is missing the library-validation entitlement." >&2
  failures=1
fi

/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_bundle"
test "$failures" -eq 0
