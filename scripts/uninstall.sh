#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user_home="${HOME}"
user_id="$(/usr/bin/id -u)"
launch_label="com.younglue.lid-audio-guard"
install_dir="${user_home}/Library/Application Support/LidAudioGuard"
launch_plist="${user_home}/Library/LaunchAgents/${launch_label}.plist"
state_file="${install_dir}/saved-audio-state.plist"
restore_bluetooth=1

usage() {
    cat <<'EOF'
Usage: ./scripts/uninstall.sh [--keep-bluetooth-wake-disabled]

  --keep-bluetooth-wake-disabled  Remove the audio guard but retain the
                                  Bluetooth wake block.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-bluetooth-wake-disabled)
            restore_bluetooth=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [[ -x "${install_dir}/lid-audio-guard" ]]; then
    "${install_dir}/lid-audio-guard" --restore-now
fi

if [[ -e "${state_file}" ]]; then
    echo "Audio state is still pending restoration: ${state_file}" >&2
    echo "Reconnect the missing output device, open the lid, and retry." >&2
    exit 1
fi

/bin/launchctl bootout \
    "gui/${user_id}/${launch_label}" >/dev/null 2>&1 || true

if [[ "${install_dir}" != \
      "${user_home}/Library/Application Support/LidAudioGuard" ]]; then
    echo "Refusing unexpected install path: ${install_dir}" >&2
    exit 2
fi

/bin/rm -f "${launch_plist}"
/bin/rm -rf "${install_dir}"
/bin/rm -f "${user_home}/Library/Logs/LidAudioGuard.log"

if [[ "${restore_bluetooth}" -eq 1 ]]; then
    "${project_root}/scripts/bluetooth-wake.sh" enable
fi

echo "Uninstalled ${launch_label}"

