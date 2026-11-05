#!/bin/sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if ! command -v zig >/dev/null && [ -x "$HOME/.metascript/zig/zig" ]; then
	PATH="$HOME/.metascript/zig:$PATH"
fi
if [ ! -f out/ghostty/libghostty-vt.a ]; then
	if git -C vendor/ghostty rev-parse HEAD >/dev/null 2>&1; then
		sh scripts/buildVt.sh
	else
		rm -rf out/ghostty-src out/ghostty
		mkdir -p out/ghostty-src out/ghostty
		cp -R vendor/ghostty/. out/ghostty-src/
		(cd out/ghostty-src && patch -p1 < ../../patches/ghostty-win32-input-mode.patch)
		(cd out/ghostty-src && zig build -Demit-lib-vt -Doptimize=ReleaseFast \
			-Dversion-string=0.0.0-dev --cache-dir ../zig-cache)
		cp -R out/ghostty-src/zig-out/lib/*ghostty-vt* out/ghostty/
	fi
fi
mkdir -p bench/out
msc build bench/serverPath.ms --release --output=bench/out/serverPath.exe
BENCH_COMMIT="${BENCH_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BENCH_MSC="${BENCH_MSC:-$(msc --version 2>/dev/null | head -1 | perl -pe "s/\\e\\[[0-9;]*m//g")}"
export BENCH_COMMIT BENCH_MSC
bench/out/serverPath.exe "$@"
