#!/usr/bin/env bash
# build.sh — compile le plugin exemple en wasm ABI v0.1.
# Les flags sont OBLIGATOIRES pour le contrat host :
#   -fno-entry   : pas de start (ADR-0007)
#   -rdynamic    : émet les exports vh_*
#   --max-memory : déclare mem.max ≤ 64Mio — gate de limites du host
#                  (sans elle, memory.grow est non borné → résiduel P0)
set -euo pipefail
cd "$(dirname "$0")"

ZIG=${ZIG:-/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig}
OUT=${OUT:-search.wasm}

"$ZIG" build-exe -target wasm32-freestanding -O ReleaseSmall \
    -fno-entry -rdynamic --max-memory=67108864 \
    --dep vh -Mroot=main.zig -Mvh=../../src/vh.zig \
    -femit-bin="$OUT"
echo "==> $OUT ($(wc -c < "$OUT") octets)"
