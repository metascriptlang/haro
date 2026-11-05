#!/bin/sh
# Builds the headless haro-server into out/haro-server/<platform>/, the bundle a window uploads, with the files it reads at run time.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in
"Linux x86_64") platform=linux-x64 ;;
"Linux aarch64" | "Linux arm64") platform=linux-arm64 ;;
"Darwin arm64") platform=macos-arm64 ;;
"Darwin x86_64") platform=macos-x64 ;;
*) echo "buildServer: no Haro server platform for $(uname -sm)" >&2; exit 1 ;;
esac
out="${1:-$root/out/haro-server/$platform}"
msc="$(command -v msc)"
toolchain="${MSC_HOME:-$(cd "$(dirname "$(readlink "$msc" || echo "$msc")")/.." && pwd)}"
version="$("$root/scripts/version.sh")"
mkdir -p "$out/assets" "$out/metascript"
(cd "$root" && msc build src/server/haroServer.ms --release --strip \
	"--passC=-DHARO_SERVER_BUILD=$version" --output="$out/haro-server")
rm -f "$out/haro-server_link.rsp"
rm -rf "$out/assets/shell" "$out/assets/haro" "$out/metascript/std"
cp -R "$root/assets/shell" "$root/assets/haro" "$out/assets/"
cp -R "$toolchain/std" "$out/metascript/std"
echo "$out/haro-server $version"
