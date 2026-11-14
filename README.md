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
open release/Volidge-1.2.1.pkg
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
`Low latency` requests an interface buffer near 2.8 ms before the output unit
starts, pins the unit's maximum render slice to the applied value, and restores
the previous buffer when routing stops. Select `Compatibility` if another audio
app requires the interface's existing buffer size.

## Latency and audio quality

The bridge uses a lock-free adaptive buffer and continuously corrects small
clock drift between the virtual device and the physical interface. It starts
with one producer callback of safety and increases that margin only after a
real underflow, avoiding a permanently oversized delay buffer.

Audio stays stereo 32-bit float at the selected interface's sample rate. There
is no lossy compression, bit-depth reduction, or nominal sample-rate change.
Frames pass through unchanged while the clocks are aligned. When independent
device clocks require fractional drift correction, Volidge uses a normalized
48-tap windowed-sinc interpolator instead of linear interpolation. Its measured
worst-case gain error at 20 kHz / 44.1 kHz is under 0.02 dB across interpolation
phases. The drift controller is limited to ±2,000 ppm and uses a deadband so it
does not resample stable, aligned streams unnecessarily.

Volidge rebuilds the route after sleep, sample-rate changes, or USB
reconnection, but hardware buffer-size notifications do not restart an active
route because the HAL output unit handles render-slice changes directly. After
an unclean shutdown, Volidge restores a stale virtual system output to the saved
physical device before attempting a new route, preventing a volume slider from
moving while audio bypasses an inactive bridge.

`Volidge` supports stereo 32-bit float audio at 44.1, 48, 88.2, 96, 176.4,
and 192 kHz. Volidge matches the device sample rate to the selected interface.

## Development

GitHub Actions builds separate Apple Silicon (`arm64`) and Intel (`x86_64`)
installers on `main` pushes, pull requests and manual runs. Each job verifies
plist versions, scripts, ad-hoc signatures, architecture slices and installer
contents without installing the driver or changing the runner's audio devices.
Download the `.pkg` and SHA-256 files from the workflow artifacts. Pushing a
`vX.Y.Z` tag matching the application, driver and installer version publishes
both successful builds to GitHub Releases. Builds do not include Developer ID
signing or notarization. Windows and Linux are not supported by this Core Audio app.

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
