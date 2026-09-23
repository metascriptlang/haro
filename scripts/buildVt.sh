#!/bin/sh
set -e
cd "$(dirname "$0")/../vendor/ghostty"
zig build -Demit-lib-vt -Doptimize=ReleaseFast
