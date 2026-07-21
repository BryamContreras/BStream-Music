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

if ! copy_tool "ffmpeg" \
  "${source_dir}/ffmpeg" \
  "${source_dir}/ffmpeg/bin/ffmpeg"; then
  missing_tools="${missing_tools} ffmpeg"
fi

if [ -n "${missing_tools}" ]; then
  if [ "${CONFIGURATION}" = "Release" ] || [ "${CONFIGURATION}" = "Profile" ]; then
    echo "error: Missing macOS desktop tools:${missing_tools}. See macos/tools/README.md."
    exit 1
  fi
  echo "warning: Missing optional macOS desktop tools:${missing_tools}. Search and downloads will be unavailable."
fi

if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && \
  [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  for tool in "${destination_dir}/yt-dlp" "${destination_dir}/ffmpeg"; do
    if [ -f "${tool}" ] && /usr/bin/file "${tool}" | /usr/bin/grep -q "Mach-O"; then
      /usr/bin/codesign \
        --force \
        --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        "${tool}"
    fi
  done
fi
