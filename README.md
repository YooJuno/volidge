# Volidge

Volidge routes macOS system audio through its built-in `Volidge` virtual audio
driver to a selected speaker or audio interface. It makes a keyboard volume knob
control the signal sent to an Audient iD14 MKII, without requiring BlackHole.

## Install

Build the integrated installer:

```sh
cd /Users/juno/Workspace/volidge
chmod +x scripts/build_pkg.sh scripts/build_driver.sh
scripts/build_pkg.sh
open release/Volidge-1.0.4.pkg
```

The installer asks for an administrator password, installs `Volidge.app` in
`/Applications`, installs `Volidge.driver` in
`/Library/Audio/Plug-Ins/HAL`, restarts Core Audio, and opens Vol. The first
launch requests Microphone permission; allow it so Vol can receive the virtual
device's audio input. Vol starts routing automatically once permission is
granted.

Choose the desired speaker or interface in Vol. It becomes the destination while
Volidge is the temporary system output. On quit or Stop Routing, Volidge restores
the previous macOS output device.

`Volidge` supports stereo 32-bit float audio at 44.1, 48, 88.2, 96, 176.4,
and 192 kHz. Vol matches the device sample rate to the selected interface.

## Development

```sh
scripts/build_app.sh
open .build/export/Volidge.app

scripts/build_driver.sh
```

`Volidge` is based on Apple's "Creating an Audio Server Driver Plug-in"
sample. Its Apple MIT license is included at
`Drivers/VolDevice/LICENSE.apple-sample.txt`.

## Limits

- Apps or DAWs explicitly configured to output directly to the iD14 bypass Vol.
- iD14 direct-monitoring audio stays under the interface's own hardware control.
- The packaged driver is ad-hoc signed for local use; public distribution needs
  Developer ID signing and notarization.
