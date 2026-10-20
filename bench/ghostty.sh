#!/bin/sh
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
ghostty=${GHOSTTY:-$root/vendor/ghostty}
data=$root/bench/out/ghosttyData
tools=$root/bench/out/ghosttyTools
mkdir -p "$data"
(cd "$ghostty" && zig build -Demit-bench -Doptimize=ReleaseFast \
	--prefix "$tools" --cache-dir "$root/out/zig-cache-bench")
gen=$tools/bin/ghostty-gen
stream=$tools/bin/ghostty-bench

"$gen" +ascii | head -c 4194304 > "$data/ghosttyAscii.bin"
"$gen" +styled --seed=42 --style-rate=0.8 | head -c 4194304 > "$data/ghosttyStyled.bin"
"$gen" +styled --seed=42 --weight-one=0 --weight-two=0.5 --weight-three=1 --grapheme-rate=0.1 |
	head -c 4194304 > "$data/ghosttyWideMix.bin"
yes "$(printf 'y\r')" | head -c 1048578 > "$data/scrolling.bin"
printf x > "$data/tiny.bin"

median() {
	for _ in 1 2 3 4 5 6 7; do
		start=$(date +%s%N)
		"$stream" +terminal-stream --terminal-cols="$2" --terminal-rows="$3" --data="$1" > /dev/null
		echo $(( ($(date +%s%N) - start) / 1000 ))
	done | sort -n | sed -n 4p
}

base=$(median "$data/tiny.bin" 120 80)
echo "process floor (tiny input): $base us"
for name in ghosttyAscii ghosttyStyled ghosttyWideMix; do
	us=$(median "$data/$name.bin" 120 80)
	echo "$name: $us us wall, $((us - base)) us above the floor, 4 MiB"
done
us=$(median "$data/scrolling.bin" 120 40)
echo "scrolling: $us us wall, $((us - base)) us above the floor, 1 MiB"
