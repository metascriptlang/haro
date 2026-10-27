#!/bin/sh
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2
failed=""
for f in $(grep -rl --include='*.ms' '^test "' src | sort); do
	out="$(msc test "$f" --tests-in-dir 2>&1)"
	rc=$?
	summary="$(printf '%s\n' "$out" | grep -E 'Tests +[0-9]' | tail -1)"
	echo "$f | ${summary:-no summary} | rc=$rc"
	if [ $rc -ne 0 ] || [ -z "$summary" ] || printf '%s' "$summary" | grep -q failed; then
		failed="$failed $f"
		printf '%s\n' "$out" | grep -E '×|AssertionError|signal|error' | head -10
	fi
done
if [ -n "$failed" ]; then
	echo "GATE RED:$failed"
	exit 1
fi
echo "GATE GREEN"
