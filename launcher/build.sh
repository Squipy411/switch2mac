#!/bin/zsh
set -eu
cd "${0:A:h}"

cache_id=$(xcrun swiftc --version | shasum -a 256 | cut -c1-16)
cache_dir="build/module-cache/$cache_id"
mkdir -p "$cache_dir"
staging=$(mktemp -d "$PWD/build/.switch2mac.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
app="$staging/Switch2Mac.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/Builder"

swift_flags=(-O)
if [[ ${SWITCH2MAC_DEBUG:-0} == 1 ]]; then swift_flags=(-Onone -D DEBUG); fi
xcrun swiftc "${swift_flags[@]}" -parse-as-library Sources/*.swift \
  -o "$app/Contents/MacOS/Switch2Mac" -target arm64-apple-macosx26.0 \
  -module-cache-path "$cache_dir" -framework SwiftUI -framework AppKit -framework CryptoKit -framework GameController
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$resources/AppIcon.icns"
cp Resources/Builder/build_service.py "$resources/Builder/"
if [[ -f ../tools/portable_game.py ]]; then
  cp ../tools/portable_game.py "$resources/Builder/"
fi
if [[ -d ../tools/portable_launcher ]]; then
  /usr/bin/ditto ../tools/portable_launcher "$resources/Builder/portable_launcher"
fi

/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
destination="build/Switch2Mac.app"
if [[ -e "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$app" "$destination"; then
  if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$destination"; fi
  exit 1
fi
printf 'Built %s\n' "$PWD/$destination"
