#!/bin/sh
set -e
cd "$(dirname "$0")/.."
mkdir -p bench/out
msc build bench/bench.ms --release --output=bench/out/haroBench.exe
bench/out/haroBench.exe --frame-kib 64 "$@"
bench/out/haroBench.exe --paced "$@"
