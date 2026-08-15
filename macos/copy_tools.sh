#!/bin/sh

set -eu

source_dir="${PROJECT_DIR}/tools"
destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/tools"

rm -rf "${destination_dir}"
mkdir -p "${destination_dir}"

copy_tool() {
  destination_name="$1"
  shift

  for candidate in "$@"; do
    if [ -f "${candidate}" ]; then
      cp "${candidate}" "${destination_dir}/${destination_name}"
      chmod 755 "${destination_dir}/${destination_name}"
      return 0
    fi
  done

  return 1
}

missing_tools=""

if ! copy_tool "yt-dlp" \
  "${source_dir}/yt-dlp" \
  "${source_dir}/yt-dlp_macos"; then
  missing_tools="${missing_tools} yt-dlp"
fi

if ! copy_tool "deno" \
  "${source_dir}/deno"; then
  missing_tools="${missing_tools} deno"
fi

if [ -n "${missing_tools}" ]; then
  if [ "${CONFIGURATION}" = "Release" ] || [ "${CONFIGURATION}" = "Profile" ]; then
    echo "error: Missing macOS desktop tools:${missing_tools}. See macos/tools/README.md."
    exit 1
  fi
  echo "warning: Missing optional macOS desktop tools:${missing_tools}. Search and downloads will be unavailable."
fi

# Keep the official PyInstaller onefile yt-dlp executable byte-for-byte intact:
# post-signing its launcher would not update its archived Python runtime.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && \
  [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  yt_dlp_tool="${destination_dir}/yt-dlp"
  if [ -f "${yt_dlp_tool}" ] && \
    /usr/bin/file "${yt_dlp_tool}" | /usr/bin/grep -q "Mach-O"; then
    if ! /usr/bin/codesign --verify --strict "${yt_dlp_tool}"; then
      echo "error: yt-dlp has an invalid upstream code signature."
      exit 1
    fi
  fi

  # Deno is a regular Mach-O executable and must share the application's
  # signing identity before the outer bundle seals its Resources directory.
  deno_tool="${destination_dir}/deno"
  if [ -f "${deno_tool}" ] && \
    /usr/bin/file "${deno_tool}" | /usr/bin/grep -q "Mach-O"; then
    /usr/bin/codesign \
      --force \
      --options runtime \
      --entitlements "${PROJECT_DIR}/Runner/Deno.entitlements" \
      --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
      "${deno_tool}"
  fi
fi

# Copy third-party notices to the Resources directory
notices_source="${PROJECT_DIR}/../THIRD_PARTY_NOTICES.md"
notices_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/THIRD_PARTY_NOTICES.md"
if [ -f "${notices_source}" ]; then
  cp "${notices_source}" "${notices_destination}"
fi
