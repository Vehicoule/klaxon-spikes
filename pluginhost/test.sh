#!/usr/bin/env bash
# tests unitaires zig (pur Zig — pas besoin de libwamr) + selftest runtime.
# Usage : test.sh  (depuis n'importe quel cwd)
set -euo pipefail
ZIG=${ZIG:-/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig}
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
"$ZIG" test src/runtime.zig
"$ZIG" test src/policy.zig
"$ZIG" test src/natives.zig
if [ -x out/pluginhost-test ]; then
    # fixture reproductible (le défaut /tmp est effacé au reboot) —
    # surcharger avec FIXTURE=<dir> pour tester un vrai dossier.
    FIX="${FIXTURE:-$ROOT/fixtures/music}"
    ./out/pluginhost-test "$ROOT/../spikes/p0-runtime/plugin/wasm" "$FIX"
fi
