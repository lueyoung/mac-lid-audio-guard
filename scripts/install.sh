#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
user_home="${HOME}"
user_id="$(/usr/bin/id -u)"
launch_label="com.younglue.lid-audio-guard"
install_dir="${user_home}/Library/Application Support/LidAudioGuard"
launch_agents_dir="${user_home}/Library/LaunchAgents"
launch_plist="${launch_agents_dir}/${launch_label}.plist"
configure_bluetooth=1

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--skip-bluetooth-wake]

  --skip-bluetooth-wake  Install/reload the lid audio guard only.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-bluetooth-wake)
            configure_bluetooth=0
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

"${project_root}/scripts/build.sh"

if [[ -x "${install_dir}/lid-audio-guard" ]]; then
    "${install_dir}/lid-audio-guard" --restore-now
fi

/bin/launchctl bootout \
    "gui/${user_id}/${launch_label}" >/dev/null 2>&1 || true

/usr/bin/install -d -m 755 "${install_dir}" "${launch_agents_dir}"
/usr/bin/install -m 755 \
    "${project_root}/build/lid-audio-guard" \
    "${install_dir}/lid-audio-guard"
/usr/bin/install -m 644 \
    "${project_root}/src/LidAudioGuard.m" \
    "${install_dir}/LidAudioGuard.m"

temporary_plist="$(/usr/bin/mktemp -t lid-audio-guard-plist)"
trap '/bin/rm -f "${temporary_plist}"' EXIT
/usr/bin/sed "s|__HOME__|${user_home}|g" \
    "${project_root}/config/${launch_label}.plist.in" \
    > "${temporary_plist}"
/usr/bin/plutil -lint "${temporary_plist}" >/dev/null
/usr/bin/install -m 644 "${temporary_plist}" "${launch_plist}"

/bin/launchctl bootstrap "gui/${user_id}" "${launch_plist}"

if [[ "${configure_bluetooth}" -eq 1 ]]; then
    "${project_root}/scripts/bluetooth-wake.sh" disable
fi

echo "Installed ${launch_label}"
echo "Run ./scripts/status.sh to verify the live state."

