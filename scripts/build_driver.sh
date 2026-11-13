#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
driver_dir="$project_root/.build/export/Volidge.driver"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$driver_dir"
rm -rf "$project_root/.build/export/VolDevice.driver"
mkdir -p "$driver_dir/Contents/MacOS" "$driver_dir/Contents/Resources"
cp "$project_root/Drivers/VolDevice/Info.plist" "$driver_dir/Contents/Info.plist"
cp "$project_root/App/VolIcon.icns" "$driver_dir/Contents/Resources/DeviceIcon.icns"

clang -std=c11 -O2 -fblocks -bundle \
  -isysroot "$sdk_path" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$driver_dir/Contents/MacOS/Volidge" \
  "$project_root/Drivers/VolDevice/VolDevice.c"

plutil -lint "$driver_dir/Contents/Info.plist"
xattr -cr "$driver_dir"
codesign --force --sign - "$driver_dir"
codesign --verify --deep --strict "$driver_dir"

echo "Built $driver_dir"
