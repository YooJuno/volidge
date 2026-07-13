#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
package_root="$project_root/.build/package-root"
release_dir="$project_root/release"
version="1.0.3"
package_path="$release_dir/Volidge-$version.pkg"

zsh "$project_root/scripts/build_app.sh"
zsh "$project_root/scripts/build_driver.sh"

rm -rf "$package_root" "$package_path"
mkdir -p "$package_root/Applications" "$package_root/Library/Audio/Plug-Ins/HAL" "$release_dir"
cp -R "$project_root/.build/export/Volidge.app" "$package_root/Applications/Volidge.app"
cp -R "$project_root/.build/export/Volidge.driver" "$package_root/Library/Audio/Plug-Ins/HAL/Volidge.driver"
find "$package_root" -name '._*' -delete
xattr -cr "$package_root"

pkgbuild \
  --root "$package_root" \
  --component-plist "$project_root/Package/Component.plist" \
  --scripts "$project_root/Package/Scripts" \
  --identifier "com.juno.volidge" \
  --version "$version" \
  --install-location / \
  "$package_path"

pkgutil --check-signature "$package_path" || true
echo "Built $package_path"
