#!/bin/sh
# Builds Haro.app with the server bundles a window uploads: this machine's, built here, and every
# out/haro-server/<platform>/ another machine built from the same version.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/out/app}"
msc="$(command -v msc)"
toolchain="$(cd "$(dirname "$(readlink "$msc" || echo "$msc")")/.." && pwd)"
app="$out/Haro.app"
res="$app/Contents/Resources"

HARO_SERVER_VERSION="$("$root/scripts/version.sh")"
export HARO_SERVER_VERSION
(cd "$root/src/app" && msc build haro.ms --release "--passC=-DHARO_SERVER_BUILD=$HARO_SERVER_VERSION")
bash "$root/../ion/scripts/make-app.sh" "$root/src/app/out/release/haro" Haro dev.haro.terminal "$out" \
	--icon="$root/assets/icon.icns"
cp -R "$root/assets" "$res/assets"
mkdir -p "$res/metascript"
cp -R "$toolchain/std" "$res/metascript/std"
"$root/scripts/buildServer.sh"
rm -rf "$res/servers"
mkdir -p "$res/servers"
for bundle in "$root"/out/haro-server/*/; do
	platform="$(basename "$bundle")"
	if grep -qF -e "$HARO_SERVER_VERSION" "$bundle/haro-server"; then
		cp -R "$bundle" "$res/servers/$platform"
	else
		echo "buildApp: out/haro-server/$platform is another version than $HARO_SERVER_VERSION, not shipped" >&2
	fi
done
ls "$res/servers"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
