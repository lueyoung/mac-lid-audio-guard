#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${project_root}/build/bluetooth-wake-control"

usage() {
    echo "Usage: $0 status|disable|enable"
}

if [[ $# -ne 1 ]]; then
    usage
    exit 64
fi

action="$1"
case "${action}" in
    status|disable|enable)
        ;;
    *)
        usage
        exit 64
        ;;
esac

if [[ ! -x "${helper}" ]]; then
    "${project_root}/scripts/build.sh"
fi

if [[ "${action}" == "status" ]]; then
    if preference_value=$(
        /usr/bin/defaults -currentHost read \
            com.apple.Bluetooth RemoteWakeEnabled 2>/dev/null
    ); then
        echo "Host preference RemoteWakeEnabled=${preference_value}"
    else
        echo "Host preference RemoteWakeEnabled=<absent>"
    fi
    "${helper}" status
    exit 0
fi

if [[ "${action}" == "disable" ]]; then
    /usr/bin/defaults -currentHost write \
        com.apple.Bluetooth RemoteWakeEnabled -bool false
    requested="disable"
else
    /usr/bin/defaults -currentHost delete \
        com.apple.Bluetooth RemoteWakeEnabled 2>/dev/null || true
    requested="enable"
fi

if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
    "${helper}" "${requested}"
else
    /usr/bin/sudo "${helper}" "${requested}"
fi

"${helper}" status

