#!/bin/sh

set -eu

resources_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
notices_source="${PROJECT_DIR}/../THIRD_PARTY_NOTICES.md"
notices_destination="${resources_dir}/THIRD_PARTY_NOTICES.md"

mkdir -p "${resources_dir}"

# Remove resolver runtimes left by an incremental build made before playback
# and downloads moved to the Dart InnerTube implementation.
rm -rf "${resources_dir}/tools"

if [ -f "${notices_source}" ]; then
  cp "${notices_source}" "${notices_destination}"
fi
