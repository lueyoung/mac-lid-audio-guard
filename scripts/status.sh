#!/bin/bash
set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user_home="${HOME}"
user_id="$(/usr/bin/id -u)"
launch_label="com.younglue.lid-audio-guard"
installed_binary="${user_home}/Library/Application Support/LidAudioGuard/lid-audio-guard"

echo "Audio guard service"
if /bin/launchctl print \
    "gui/${user_id}/${launch_label}" >/dev/null 2>&1; then
    /bin/launchctl print "gui/${user_id}/${launch_label}" |
        /usr/bin/grep -E \
            'state =|runs =|pid =|last exit code|path =|program ='
else
    echo "  not loaded"
fi

echo
echo "Audio state"
if [[ -x "${installed_binary}" ]]; then
    "${installed_binary}" --status
elif [[ -x "${project_root}/build/lid-audio-guard" ]]; then
    "${project_root}/build/lid-audio-guard" --status
else
    echo "  binary not built or installed"
fi

echo
echo "Bluetooth wake state"
"${project_root}/scripts/bluetooth-wake.sh" status

