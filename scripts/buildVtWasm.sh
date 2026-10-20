#!/bin/sh
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/out/ghostty-wasm-src"
out="$root/out/wasm"
objdump="${LLVM_OBJDUMP:-llvm-objdump}"
command -v "$objdump" >/dev/null || { echo "llvm-objdump not found, set LLVM_OBJDUMP" >&2; exit 1; }

rm -rf "$src" "$out"
mkdir -p "$src" "$out"
git -C "$root/vendor/ghostty" archive HEAD | tar -x -C "$src"
rev="$(git -C "$root/vendor/ghostty" rev-parse --short=7 HEAD)"
cd "$root"
git apply --directory=out/ghostty-wasm-src patches/ghostty-wasm-embedder.patch
git apply --directory=out/ghostty-wasm-src patches/ghostty-win32-input-mode.patch

cd "$src"
zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=wasm32-freestanding \
	-Dversion-string="0.0.0-dev+$rev" --cache-dir "$root/out/zig-cache-wasm"
cp zig-out/lib/libghostty-vt.a "$out/libghostty-vt.a"

"$objdump" -d "$out/libghostty-vt.a" >disassembly.txt
grep -q 'file format wasm' disassembly.txt || { echo "llvm-objdump did not read libghostty-vt.a as wasm" >&2; exit 1; }
grows="$(grep -c 'memory\.grow' disassembly.txt || true)"
echo "memory.grow instructions in libghostty-vt.a: $grows"
[ "$grows" = 0 ] || { echo "libghostty-vt.a still grows linear memory itself" >&2; exit 1; }
