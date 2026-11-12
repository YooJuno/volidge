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
open release/Volidge-1.2.0.pkg
```

The installer asks for an administrator password, installs `Volidge.app` in
`/Applications`, installs `Volidge.driver` in
`/Library/Audio/Plug-Ins/HAL`, restarts Core Audio, and opens Volidge. When the
selected device needs the audio bridge, the first launch requests Microphone
permission so Volidge can read its virtual audio input. macOS shows an orange
microphone indicator while bridging, but Volidge does not read the Mac's
physical microphone.

Choose the desired speaker or interface in Volidge. It becomes the destination
while Volidge is the temporary system output. The destination's own volume is
temporarily set to 100%, making Volidge the only volume stage, and is restored
when routing stops. Changing the macOS output directly stops routing to prevent
direct and delayed audio from playing together.

AirPods and Mac speakers already support macOS volume control, so Volidge sends
audio to them directly with no bridge, added latency, or microphone indicator.
Interfaces such as the Audient iD14 use the low-latency bridge.
`Low latency` temporarily requests a 256-frame hardware buffer and restores the
previous value when routing stops. Select `Compatibility` if another audio app
requires the interface's existing buffer size.

The bridge uses a lock-free buffer and continuously corrects small clock drift
between the virtual device and the physical interface. Volidge also rebuilds
the route after sleep, sample-rate changes, or USB reconnection.

`Volidge` supports stereo 32-bit float audio at 44.1, 48, 88.2, 96, 176.4,
and 192 kHz. Volidge matches the device sample rate to the selected interface.

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

- Apps or DAWs explicitly configured to a physical output bypass Volidge.
- iD14 direct-monitoring audio stays under the interface's own hardware control.
- The packaged driver is ad-hoc signed for local use; public distribution needs
  Developer ID signing and notarization.
