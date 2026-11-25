#!/usr/bin/env bash
# Compatibility entry point for the validated Android arm64 profile engine.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "Usage: $0 <isolated Flutter 3.47.9 checkout> <output libflutter.so>" >&2
  exit 2
fi
exec bash "$(dirname "${BASH_SOURCE[0]}")/build_android_engine.sh" profile "$1" "$2"
