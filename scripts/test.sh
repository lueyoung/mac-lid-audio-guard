#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_live_test=1

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--no-live-test]" >&2
    exit 64
fi
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--no-live-test" ]]; then
        echo "Usage: $0 [--no-live-test]" >&2
        exit 64
    fi
    run_live_test=0
fi

"${project_root}/scripts/build.sh"

/usr/bin/clang \
    --analyze \
    -fobjc-arc \
    -fblocks \
    -Wall \
    -Wextra \
    -Xanalyzer -analyzer-output=text \
    "${project_root}/src/LidAudioGuard.m"

/bin/bash -n \
    "${project_root}/scripts/build.sh" \
    "${project_root}/scripts/bluetooth-wake.sh" \
    "${project_root}/scripts/install.sh" \
    "${project_root}/scripts/status.sh" \
    "${project_root}/scripts/test.sh" \
    "${project_root}/scripts/uninstall.sh"

temporary_plist="$(/usr/bin/mktemp -t lid-audio-guard-test-plist)"
trap '/bin/rm -f "${temporary_plist}"' EXIT
/usr/bin/sed "s|__HOME__|${HOME}|g" \
    "${project_root}/config/com.younglue.lid-audio-guard.plist.in" \
    > "${temporary_plist}"
/usr/bin/plutil -lint "${temporary_plist}"

"${project_root}/build/bluetooth-wake-control" status

if [[ "${run_live_test}" -eq 1 ]]; then
    "${project_root}/build/lid-audio-guard" --test-cycle
else
    echo "Skipped live CoreAudio mute/restore test."
fi

echo "All requested checks passed."

