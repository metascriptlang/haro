#!/bin/bash
# Drives a built haro-server end to end on a private socket: start, status, proxy, a killed proxy, stop.
# usage: scripts/serverCheck.sh path/to/haro-server
set -u
bin="$1"
work="$(mktemp -d)"
export HARO_SOCKET="$work/run/haro.sock"
state="$work/state"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
hello='\000\000\000\021\000\000\000\000\001\000\000\000\000\120\000\000\000\030\000\000\000\000\000\000\000\000\002'
pidOf() { "$bin" status | sed -n 's/^pid //p'; }
clientsOf() { "$bin" status | sed -n 's/^attached clients //p'; }

"$bin" version
check "version names protocol and vt" '"$bin" version | grep -q "protocol [0-9]* vt "'
check "start detaches a server" '"$bin" start --state-dir "$state"'
check "a second start is refused" '! "$bin" start --state-dir "$state"'
first="$(pidOf)"
check "status names a pid" '[ -n "$first" ]'
"$bin" status

(printf "$hello"; sleep 60) | setsid "$bin" proxy --state-dir "$state" > "$work/out1" 2> "$work/err1" &
sleep 2
proxied="$(pgrep -f "$bin proxy" | head -1)"
check "the proxy relays the server's Welcome first" '[ "$(od -An -tx1 -j4 -N1 "$work/out1" | tr -d " ")" = 01 ]'
check "the proxied client is attached" '[ "$(clientsOf)" = 1 ]'
"$bin" status
kill -HUP -- "-$(ps -o pgid= "$proxied" | tr -d ' ')" 2>/dev/null
kill -9 "$proxied" 2>/dev/null
sleep 1
check "the server outlives a hung-up, killed proxy" '[ "$(pidOf)" = "$first" ]'
check "the killed proxy's client is gone" '[ "$(clientsOf)" = 0 ]'
check "the server's shell outlives the proxy" '[ -n "$(pgrep -P "$first")" ]'

(printf "$hello"; sleep 1) | "$bin" proxy --state-dir "$state" > "$work/out2" 2>&1
check "a proxy whose stdin ends exits and leaves the server" '[ "$(pidOf)" = "$first" ] && [ -s "$work/out2" ]'

(printf "$hello"; sleep 60) | "$bin" proxy --state-dir "$state" > "$work/out3" 2>&1 &
sleep 2
check "stop through the protocol" '"$bin" stop'
waited=0
while pgrep -f "$bin proxy" > /dev/null && [ $waited -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
check "a proxy ends when its server stops" '! pgrep -f "$bin proxy" > /dev/null'
check "no server answers after stop" '! "$bin" status > /dev/null'
check "the stopped server's shells are gone" '[ -z "$(pgrep -P "$first")" ] && ! kill -0 "$first" 2>/dev/null'

(printf "$hello"; sleep 1) | "$bin" proxy --state-dir "$state" > "$work/out4" 2> "$work/err4"
second="$(pidOf)"
check "a proxy starts a server when none answers" '[ -n "$second" ] && [ "$second" != "$first" ] && [ -s "$work/out4" ]'
check "logs prints the detached log" '"$bin" logs --state-dir "$state" | grep -q "serving"'
"$bin" logs --state-dir "$state" | tail -5
"$bin" stop > /dev/null
pkill -f "sleep 60" 2>/dev/null
rm -rf "$work"
echo "server check: $fails failed"
[ $fails -eq 0 ]
