#!/bin/zsh
set -eu
project_dir="${0:A:h}"
cd "$project_dir"
build_dir="$project_dir/Build"
app_dir="$project_dir/InkDesk.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
sdk_path="$(xcrun --show-sdk-path)"
build_arch="$(uname -m)"
swiftc -parse-as-library -swift-version 5 -O -sdk "$sdk_path" \
  -target "$build_arch-apple-macos14.0" \
  Sources/InkDesk/*.swift Tests/*.swift \
  -o "$app_dir/Contents/MacOS/InkDesk"
cp Info.plist "$app_dir/Contents/Info.plist"
cp Assets/AppIcon-ImageGen.icns "$app_dir/Contents/Resources/AppIcon-ImageGen.icns"
codesign --force --sign - --identifier fan.api.InkDesk "$app_dir" >/dev/null
print "Built: $app_dir"
if [[ "${1:-}" == "--test" ]]; then "$app_dir/Contents/MacOS/InkDesk" --self-test; fi
