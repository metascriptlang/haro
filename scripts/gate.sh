#!/bin/sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2
jobs="${GATE_JOBS:-4}"
logs="$(mktemp -d)"
trap 'rm -rf "${logs:?}"' EXIT
files="$(grep -rlE --include='*.ms' '^[[:space:]]*test "' src | sort)"
printf '%s\n' "$files" | xargs -P "$jobs" -I{} sh -c 'msc test "$1" --tests-in-dir > "$2/$(echo "$1" | tr / _)" 2>&1; echo $? >> "$2/$(echo "$1" | tr / _)"' _ {} "$logs"
failed=""
for f in $files; do
	log="$logs/$(echo "$f" | tr / _)"
	rc="$(tail -1 "$log")"
	out="$(sed '$d' "$log")"
	summary="$(printf '%s\n' "$out" | grep -E 'Tests +[0-9]' | tail -1)"
	echo "$f | ${summary:-no summary} | rc=$rc"
	if [ "$rc" -ne 0 ] || [ -z "$summary" ] || printf '%s' "$summary" | grep -q failed; then
		failed="$failed $f"
		printf '%s\n' "$out" | grep -E '×|AssertionError|signal|error' | head -10
	fi
done
if [ -n "$failed" ]; then
	echo "GATE RED:$failed"
	exit 1
fi
echo "GATE GREEN"
