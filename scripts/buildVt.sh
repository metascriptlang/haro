#!/bin/sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/out/ghostty-src"
out="$root/out/ghostty"

rm -rf "$src" "$out"
mkdir -p "$src" "$out"
git -C "$root/vendor/ghostty" archive HEAD | tar -x -C "$src"
rev="$(git -C "$root/vendor/ghostty" rev-parse --short=7 HEAD)"
cd "$root"
git apply --directory=out/ghostty-src patches/ghostty-win32-input-mode.patch

cd "$src"
zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dversion-string="0.0.0-dev+$rev" --cache-dir "$root/out/zig-cache"
cp -R zig-out/lib/*ghostty-vt* "$out/"
