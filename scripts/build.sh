#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${project_root}/build"

/bin/mkdir -p "${build_dir}"

/usr/bin/clang \
    -fobjc-arc \
    -fblocks \
    -Wall \
    -Wextra \
    -Werror \
    -O2 \
    -framework Foundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework IOKit \
    "${project_root}/src/LidAudioGuard.m" \
    -o "${build_dir}/lid-audio-guard"

/usr/bin/clang \
    -Wall \
    -Wextra \
    -Werror \
    -O2 \
    -framework CoreFoundation \
    -framework IOKit \
    "${project_root}/src/BluetoothWakeControl.c" \
    -o "${build_dir}/bluetooth-wake-control"

echo "Built:"
echo "  ${build_dir}/lid-audio-guard"
echo "  ${build_dir}/bluetooth-wake-control"

