#!/bin/zsh
set -e

root="${0:A:h}"
app="$root/build/Photoframe.app"
iconset="$root/build/Photoframe.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Info.plist" "$app/Contents/Info.plist"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
  -module-cache-path "$root/build/PhotoframeModuleCache" \
  -Xfrontend -downgrade-typecheck-interface-error \
  -framework AppKit "$root/Icon.swift" -o "$root/build/create-icon"
"$root/build/create-icon" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Photoframe.icns"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
  -module-cache-path "$root/build/PhotoframeModuleCache" \
  -Xfrontend -downgrade-typecheck-interface-error \
  -framework AppKit -framework CoreImage -framework ImageIO \
  -framework UniformTypeIdentifiers \
  "$root/main.swift" -o "$app/Contents/MacOS/Photoframe"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
