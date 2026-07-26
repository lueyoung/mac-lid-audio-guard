# mac-lid-audio-guard

English | [简体中文](README.zh-CN.md)

A macOS utility that mutes audio when a MacBook lid is closed and prevents Bluetooth devices from waking the Mac. It helps keep Bluetooth keyboards and mice from waking a closed MacBook and stops music, videos, or system alerts from playing unexpectedly at night.

The project provides two independent layers of protection:

```text
Bluetooth HID activity
    └─ RemoteWakeEnabled = false

Lid-close event
    ├─ Save the original output routes, mute states, and volume levels
    ├─ Mute every controllable output device
    ├─ Route default and system audio to a muted safe device
    ├─ Pause active media services
    └─ Restore the exact previous state and remove temporary state after the lid opens
```

## Verified environment

- macOS 26.5.2
- Apple Silicon (M4)
- DELL S2725QC external monitor
- Built-in MacBook speakers
- QQ Music 11.7.0
- MX2.0S Bluetooth LE keyboard

## Quick start

```bash
cd ~/workspace/mac-lid-audio-guard
./scripts/test.sh
./scripts/install.sh
./scripts/status.sh
```

Installing Bluetooth wake prevention requires administrator privileges once so that
`RemoteWakeEnabled=false` can be applied immediately to the active Bluetooth controller. This does not affect the Bluetooth power state, pairing records, or normal Bluetooth use while the Mac is awake.

To install or update only the lid-close audio listener while keeping the current Bluetooth settings:

```bash
./scripts/install.sh --skip-bluetooth-wake
```

## Common commands

```bash
make build
make test
make status

./scripts/bluetooth-wake.sh status
./scripts/bluetooth-wake.sh disable
./scripts/bluetooth-wake.sh enable

./scripts/uninstall.sh
```

`test.sh` checks compiler warnings, runs Clang static analysis, validates shell syntax and the LaunchAgent plist, and performs a short live test covering “mute → safe routing → state persistence → simulated restart → exact restoration.” The test does not intentionally play any audio.

To run static checks only:

```bash
./scripts/test.sh --no-live-test
```

## Installation paths

- Listener: `~/Library/Application Support/LidAudioGuard/lid-audio-guard`
- Login item: `~/Library/LaunchAgents/com.younglue.lid-audio-guard.plist`
- Log: `~/Library/Logs/LidAudioGuard.log`
- Recovery state while the lid is closed: `~/Library/Application Support/LidAudioGuard/saved-audio-state.plist`

The recovery state exists only while lid-close protection is active. It should be removed automatically after the lid is opened normally.

## Project structure

```text
src/LidAudioGuard.m              Lid events and CoreAudio mute/restore logic
src/BluetoothWakeControl.c       Live Bluetooth remote-wake property control
config/*.plist.in                LaunchAgent template
scripts/build.sh                 Build the two native arm64 utilities
scripts/install.sh               Install and load
scripts/uninstall.sh             Restore state and uninstall
scripts/status.sh                Read-only runtime status checks
scripts/test.sh                  Static checks and live restoration test
docs/incident-and-design.md      Original incident and design boundaries
```

## Design notes

Lid-close muting uses public IOKit lid notifications and CoreAudio properties. Media pausing uses the system-provided MediaRemote channel as an additional safeguard. Even if a future macOS version stops accepting media pause commands, muting and safe routing remain the primary defenses.

For the full background, see [docs/incident-and-design.md](docs/incident-and-design.md).
