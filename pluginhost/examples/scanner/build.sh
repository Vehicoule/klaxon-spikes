#!/usr/bin/env bash
# build.sh — compile le plugin scanner en wasm ABI v0.1.
# -fno-entry/-rdynamic/--max-memory=64Mio : flags obligatoires du contrat host.
set -euo pipefail
cd "$(dirname "$0")"

ZIG=${ZIG:-/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig}
OUT=${OUT:-scanner.wasm}

"$ZIG" build-exe -target wasm32-freestanding -O ReleaseSmall \
    -fno-entry -rdynamic --max-memory=67108864 \
    --dep vh -Mroot=main.zig -Mvh=../../../sdk/src/vh.zig \
    -femit-bin="$OUT"
echo "==> $OUT ($(wc -c < "$OUT") octets)"
