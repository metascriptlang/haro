#!/bin/sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/out/app}"
msc="$(command -v msc)"
toolchain="$(cd "$(dirname "$(readlink "$msc" || echo "$msc")")/.." && pwd)"
app="$out/Haro.app"
res="$app/Contents/Resources"

(cd "$root/src/app" && msc build haro.ms --release)
bash "$root/../ion/scripts/make-app.sh" "$root/src/app/out/release/haro" Haro dev.haro.terminal "$out" \
	--icon="$root/assets/icon.icns"
cp -R "$root/assets" "$res/assets"
mkdir -p "$res/metascript"
cp -R "$toolchain/std" "$res/metascript/std"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
