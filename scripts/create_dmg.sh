#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
release_dir="$project_root/release"
staging_dir="$release_dir/dmg-staging"
dmg_path="$release_dir/Volidge.dmg"
read_write_dmg="$release_dir/Vol-rw.dmg"
mount_point="$release_dir/dmg-mount"

zsh "$project_root/scripts/build_app.sh"

rm -rf "$staging_dir" "$dmg_path" "$read_write_dmg" "$mount_point"
mkdir -p "$staging_dir/.background" "$mount_point"
ditto "$project_root/.build/export/Volidge.app" "$staging_dir/Volidge.app"
ln -s /Applications "$staging_dir/Applications"
sips -s format png "$project_root/App/dmg-background.svg" --out "$staging_dir/.background/drag-to-install.png" >/dev/null

hdiutil create \
  -volname "Volidge" \
  -srcfolder "$staging_dir" \
  -format UDRW \
  -ov \
  "$read_write_dmg" >/dev/null

hdiutil attach -noverify -mountpoint "$mount_point" "$read_write_dmg" >/dev/null

if ! osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Volidge"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 760, 500}
        set viewOptions to icon view options of container window
        set icon size of viewOptions to 96
        set arrangement of viewOptions to not arranged
        set background picture of viewOptions to file ".background:drag-to-install.png"
        set position of item "Volidge.app" to {150, 235}
        set position of item "Applications" to {510, 235}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
  echo "Finder could not save the custom DMG layout; creating a standard drag-and-drop DMG instead." >&2
fi

hdiutil detach "$mount_point" >/dev/null
hdiutil convert "$read_write_dmg" -format UDZO -o "$dmg_path" >/dev/null

rm -rf "$staging_dir" "$mount_point" "$read_write_dmg"
echo "Created $dmg_path"
