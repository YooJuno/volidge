#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/dist/Vol.app"
destination_root="$HOME/Applications"
destination_app="$destination_root/Vol.app"

zsh "$project_root/scripts/build_app.sh"
mkdir -p "$destination_root"
rm -rf "$destination_app"
ditto "$source_app" "$destination_app"
xattr -cr "$destination_app"
codesign --force --sign - "$destination_app"

echo "Installed $destination_app"
