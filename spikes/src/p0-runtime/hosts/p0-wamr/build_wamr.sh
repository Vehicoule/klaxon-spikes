#!/bin/bash
# Build WAMR fast-interp minimal (pas de cmake) + harnais p0-wamr
set -e
ROOT=/home/ubuntu/work/Klaxon/spikes/p0-runtime/hosts
W=$ROOT/wamr
OUT=$ROOT/p0-wamr/out
mkdir -p $OUT

INC="-I$W/core/iwasm/include -I$W/core/iwasm/common -I$W/core/iwasm/interpreter \
-I$W/core/shared/include -I$W/core/shared/utils -I$W/core/shared/utils/uncommon \
-I$W/core/shared/mem-alloc -I$W/core/shared/mem-alloc/ems \
-I$W/core/shared/platform/include -I$W/core/shared/platform/linux \
-I$W/core/shared/platform/common/posix -I$W/core/shared/platform/common/libc-util"
DEF="-DBH_PLATFORM_LINUX -DWASM_ENABLE_INTERP=1 -DWASM_ENABLE_FAST_INTERP=1 \
-DWASM_ENABLE_AOT=0 -DWASM_ENABLE_JIT=0 -DWASM_ENABLE_LIBC_BUILTIN=0 \
-DWASM_ENABLE_LIBC_WASI=0 -DWASM_ENABLE_BULK_MEMORY=1 -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_SIMD=0 \
-DWASM_ENABLE_REF_TYPES=1 -DWASM_ENABLE_CALL_INDIRECT_OVERLONG=1 \
-DWASM_ENABLE_WAKEUP_BLOCKING_OP=1 -DWASM_ENABLE_INSTRUCTION_METERING=1 \
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
SRCS="$SRCS $ROOT/p0-wamr/main_wamr.c"

gcc -O2 -fno-omit-frame-pointer $DEF $INC $SRCS -o $OUT/p0-wamr -lpthread -lm -ldl 2>&1 | head -30
echo "=== build done ==="; ls -la $OUT/p0-wamr 2>/dev/null
