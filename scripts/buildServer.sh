#!/bin/sh
# Builds the headless haro-server into out/haro-server/<os>-<arch>/ with the files it reads at run time.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
out="${1:-$root/out/haro-server/$os-$arch}"
msc="$(command -v msc)"
toolchain="${MSC_HOME:-$(cd "$(dirname "$(readlink "$msc" || echo "$msc")")/.." && pwd)}"
version="$("$root/scripts/version.sh")"
mkdir -p "$out/assets" "$out/metascript"
(cd "$root" && msc build src/server/haroServer.ms --release --strip \
	"--passC=-DHARO_SERVER_BUILD=$version" --output="$out/haro-server")
rm -rf "$out/assets/shell" "$out/assets/haro" "$out/metascript/std"
cp -R "$root/assets/shell" "$root/assets/haro" "$out/assets/"
cp -R "$toolchain/std" "$out/metascript/std"
echo "$out/haro-server $version"
