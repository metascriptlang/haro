#!/bin/sh
# Prints the build version a window and the haro-server it uploads must share: HARO_SERVER_VERSION, else the commit.
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${HARO_SERVER_VERSION:-$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null || echo dev)}"
if [ -z "${HARO_SERVER_VERSION:-}" ] && [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then version="$version-dirty"; fi
echo "$version"
