#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/.build/export/Volidge.app"
destination_root="$HOME/Applications"
destination_app="$destination_root/Volidge.app"

zsh "$project_root/scripts/build_app.sh"
mkdir -p "$destination_root"
rm -rf "$destination_root/Vol.app"
rm -rf "$destination_app"
ditto "$source_app" "$destination_app"
xattr -cr "$destination_app"
codesign --force --sign - "$destination_app"

echo "Installed $destination_app"
