# Incident and design notes

## Why this exists

The original incident was not a scheduled QQ Music action. The Mac slept after
the lid was closed, then a Bluetooth LE HID event produced a full wake while
the lid was still closed. QQ Music and CoreAudio resumed during that wake, so
sound could be emitted at night.

The paired device implicated by the local logs was:

- Name: `MX2.0S WL Pro-BT1`
- Transport: Bluetooth LE HID
- Vendor ID: `0x0687`
- Product ID: `0x01DE`

There was no matching media play/pause command in the event window. This is why
the project treats wake prevention and audible-output prevention as separate
layers.

## Layer 1: block Bluetooth remote wake

`RemoteWakeEnabled` is written to the current-host Bluetooth preferences so it
survives restart. The same property is applied immediately to the live
`IOBluetoothHCIController`; that live write requires administrator privileges.

Bluetooth itself remains enabled. Existing pairing records and normal awake
usage are not changed.

## Layer 2: make a closed lid silent

`LidAudioGuard` listens for `kIOPMMessageClamshellStateChange` from
`IOPMrootDomain`.

On close it:

1. saves current output routes and per-device mute/volume controls;
2. mutes every controllable output;
3. routes default application and system sound to a muted safe device;
4. sends an idempotent Pause command to the current media service;
5. rechecks the lid and audio-device topology every five seconds while awake.

On open it restores routes and controls, including recovery from the persisted
state file after an agent crash or user-session restart.

The current DELL S2725QC output exposes no CoreAudio mute/volume control. It is
therefore protected by safe routing to the muted built-in speaker while the lid
is closed, then restored on open.

## Boundaries

The safe-route layer covers normal applications that follow the macOS default
output and all system sounds. An application deliberately pinned to a separate,
non-mutable hardware device can bypass the default route; the repeated media
Pause command is the secondary protection for that case.

