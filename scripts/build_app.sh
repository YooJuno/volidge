#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_dir="$project_root/.build/release"
app_dir="$project_root/.build/export/Volidge.app"

cd "$project_root"
swift build --configuration release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/Vol" "$app_dir/Contents/MacOS/Vol"
cp "$project_root/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_root/App/VolIcon.icns" "$app_dir/Contents/Resources/VolIcon.icns"
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir"

echo "Built $app_dir"
