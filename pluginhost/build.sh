#!/usr/bin/env bash
# build.sh — construit libwamr.a (fast-interp, flags P0) + pluginhost-test.
# La recette WAMR reprend spikes/p0-runtime/hosts/p0-wamr/build_wamr.sh.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=/home/ubuntu/work/Klaxon
W=$ROOT/spikes/p0-runtime/hosts/wamr
OUT=out
mkdir -p "$OUT/obj"

INC="-I$W/core/iwasm/include -I$W/core/iwasm/common -I$W/core/iwasm/interpreter \
-I$W/core/shared/include -I$W/core/shared/utils -I$W/core/shared/utils/uncommon \
-I$W/core/shared/mem-alloc -I$W/core/shared/mem-alloc/ems \
-I$W/core/shared/platform/include -I$W/core/shared/platform/linux \
-I$W/core/shared/platform/common/posix -I$W/core/shared/platform/common/libc-util -I$W/core/iwasm/libraries/thread-mgr"
DEF="-DBH_PLATFORM_LINUX -DWASM_ENABLE_INTERP=1 -DWASM_ENABLE_FAST_INTERP=1 \
-DWASM_ENABLE_AOT=0 -DWASM_ENABLE_JIT=0 -DWASM_ENABLE_LIBC_BUILTIN=0 \
-DWASM_ENABLE_LIBC_WASI=0 -DWASM_ENABLE_BULK_MEMORY=1 -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_SIMD=0 \
-DWASM_ENABLE_REF_TYPES=1 -DWASM_ENABLE_CALL_INDIRECT_OVERLONG=1 \
-DWASM_ENABLE_WAKEUP_BLOCKING_OP=1 -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_THREAD_MGR=1 \
-DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free"

SRCS=""
SRCS="$SRCS $(ls $W/core/iwasm/common/*.c)"
SRCS="$SRCS $W/core/iwasm/common/arch/invokeNative_em64.s"
SRCS="$SRCS $W/core/shared/platform/common/libc-util/libc_errno.c"
SRCS="$SRCS $W/core/shared/platform/common/memory/mremap.c"
SRCS="$SRCS $W/core/iwasm/interpreter/wasm_interp_fast.c $W/core/iwasm/interpreter/wasm_loader.c $W/core/iwasm/interpreter/wasm_runtime.c"
SRCS="$SRCS $(find $W/core/shared/mem-alloc -name '*.c')"
SRCS="$SRCS $(find $W/core/shared/utils -name '*.c')"
SRCS="$SRCS $(find $W/core/shared/platform/linux -name '*.c') $(find $W/core/shared/platform/common/posix -name '*.c')"
SRCS="$SRCS $W/core/iwasm/libraries/thread-mgr/thread_manager.c"

# libwamr.a incrémentale (recompile uniquement les sources modifiées)
NEED=0
for s in $SRCS; do
    o="$OUT/obj/$(basename "$s" | sed 's/\.[cs]$//')_$(echo "$s" | md5sum | cut -c1-6).o"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
        gcc -O2 -fno-omit-frame-pointer $DEF $INC -c "$s" -o "$o"
        NEED=1
    fi
done
if [ ! -f "$OUT/libwamr.a" ] || [ "$NEED" = 1 ]; then
    ar rcs "$OUT/libwamr.a" "$OUT"/obj/*.o
fi
echo "libwamr.a : $(wc -c < "$OUT/libwamr.a") octets"

ZIG=${ZIG:-/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig}
"$ZIG" build-exe src/selftest.zig -O ReleaseFast -lc \
    "$OUT/libwamr.a" -lpthread -ldl -lm \
    -femit-bin="$OUT/pluginhost-test"
echo "==> $OUT/pluginhost-test"
