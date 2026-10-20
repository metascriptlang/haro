#!/bin/sh
# Builds one probe entry (neonRows or neonVoid) for the browser with --os=emcc. This mirrors
# void's scripts/build-web.sh step for step (pinned emscripten, Windows emcc shims, msc
# retried on the uncached async-emcc path); only the entry, the preload list and the output
# directory differ, so nothing is written into the void checkout's out/.
#
#   HARO_WEB_OUT=<dir> sh probe/web/ui/buildWeb.sh neonRows [gl|wgpu ...]
#
# Writes <dir>/site/{gl,wgpu}/<name>.{js,wasm,data}; <dir>/site/index.html is the loader page.
set -e

NAME="${1:?entry name: neonRows or neonVoid}"
shift
BACKENDS="${*:-gl}"
OUT="${HARO_WEB_OUT:?set HARO_WEB_OUT to a scratch directory}"

HERE="$(cd "$(dirname "$0")" && pwd)"
VOID="${VOID_DIR:-$HERE/../../../../void}"
VOID="$(cd "$VOID" && pwd)"
WORKTREE="$(cd "$HERE/../../.." && pwd)"
EMSDK_DIR="${EMSDK_DIR:-${EMSDK:?set EMSDK_DIR or EMSDK to the emsdk checkout}}"
MSC="${MSC:-msc}"
MSC_FLAGS="${HARO_WEB_MSCFLAGS:-}"
EMSCRIPTEN_VERSION="$(cat "$VOID/.emscripten-version")"

mkdir -p "$OUT/obj" "$OUT/site" "$OUT/log"

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	SHIM="$OUT/emcc-shim"
	mkdir -p "$SHIM"
	clang -O2 -D_CRT_SECURE_NO_WARNINGS -o "$SHIM/emcc.exe" "$VOID/scripts/emccShim.c"
	for tool in em++ emar emranlib; do cp "$SHIM/emcc.exe" "$SHIM/$tool.exe"; done
	VOID_EMSDK_ROOT="$EMSDK_DIR"
	VOID_EMSDK_PYTHON="$(ls -d "$EMSDK_DIR"/python/*/python.exe 2>/dev/null | head -1)"
	[ -x "$VOID_EMSDK_PYTHON" ] || { echo "no emsdk python under $EMSDK_DIR/python"; exit 1; }
	EM_CONFIG="$EMSDK_DIR/.emscripten"
	export VOID_EMSDK_ROOT VOID_EMSDK_PYTHON EM_CONFIG
	PATH="$SHIM:$PATH"
	export PATH
	;;
*)
	. "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
	;;
esac
active="$(cat "$EMSDK_DIR/upstream/emscripten/emscripten-version.txt" 2>/dev/null | tr -d '"')"
if [ "$active" != "$EMSCRIPTEN_VERSION" ]; then
	echo "emscripten is $active, .emscripten-version pins $EMSCRIPTEN_VERSION"
	exit 1
fi

# void's own default font (void2d loads assets/font.ttf) and Haro's, as paths relative to the
# void checkout, the directory msc runs from.
FONT_REL="$(realpath --relative-to="$VOID" "$WORKTREE/assets/JetBrainsMonoNL-Regular.ttf")"
PRELOAD="--preload-file assets/font.ttf --preload-file $FONT_REL@assets/JetBrainsMonoNL-Regular.ttf"

cd "$VOID"
build() {
	dir="$1"; api="$2"
	rm -f "$OUT/obj/$NAME.js" "$OUT/obj/$NAME.wasm" "$OUT/obj/$NAME.data"
	for i in 1 2 3 4; do
		"$MSC" build $MSC_FLAGS "$HERE/$NAME.ms" --os=emcc "-d:$api" --passL="$PRELOAD" \
			--output="$OUT/obj/$NAME.js" >"$OUT/log/$NAME.$dir.log" 2>&1 || true
		if grep -q "Built" "$OUT/log/$NAME.$dir.log" && [ -f "$OUT/obj/$NAME.wasm" ]; then
			mkdir -p "$OUT/site/$dir"
			cp "$OUT/obj/$NAME.js" "$OUT/obj/$NAME.wasm" "$OUT/obj/$NAME.data" "$OUT/site/$dir/"
			echo "$NAME $dir (attempt $i)"
			return 0
		fi
	done
	echo "$NAME $dir FAILED after retries, see $OUT/log/$NAME.$dir.log"
	return 1
}

for b in $BACKENDS; do
	case "$b" in
	gl) build gl webgl2 ;;
	wgpu) build wgpu webgpu ;;
	*) echo "unknown backend $b"; exit 1 ;;
	esac
done
cp "$HERE/index.html" "$OUT/site/index.html"
