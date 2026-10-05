#!/usr/bin/env bash
# Build de Vehicoule V0 (lecteur musical local) :
# shim kx_skia + décodeurs (dr_libs + stb_vorbis + opusfile/libopus/libogg
# vendored pur-C) + pluginhost WAMR + zig.
set -euo pipefail
ROOT=/home/ubuntu/work/Klaxon
SKIA=$ROOT/spikes/w0-graphite-wasm/deps/skia
ZIG=/home/ubuntu/tools/zig-x86_64-linux-0.17.0/zig
SDL=/home/ubuntu/work/Klaxon/spikes/k1-sdl/deps/SDL3-build
WAMR=$ROOT/pluginhost/out/libwamr.a
V=$ROOT/vehicoule/vendor
OUT=$ROOT/vehicoule/out
GOUT=$ROOT/gallery/out   # objets shim déjà compilés (mêmes flags)
mkdir -p "$OUT/obj"
cd "$ROOT"

if [ ! -f "$GOUT/kx_a11y_linux.o" ]; then
    echo "shim objets manquants — lance gallery/build.sh d'abord" >&2; exit 1
fi

# --- décodeurs vendored ----------------------------------------------------
OPINC="-I$V/opus/include -I$V/opus/celt -I$V/opus/silk -I$V/opus/silk/float -I$V/opus/src"
OFINC="-I$V/ogg/include -I$V/opusfile/include $OPINC"
OPDEF="-DOPUS_BUILD -DUSE_ALLOCA -DHAVE_ALLOCA_H -DHAVE_LRINT -DHAVE_LRINTF -DHAVE_LROUND -DVAR_ARRAYS"

cc_obj() { # src, extra flags
    local s="$1"; shift
    local o="$OUT/obj/$(basename "${s%.*}")_$(echo "$s" | md5sum | cut -c1-6).o"
    if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then
        gcc -O2 $* -c "$s" -o "$o"
    fi
    OBJS="$OBJS $o"
}

OBJS=""
cc_obj vehicoule/decoder.c $OFINC
cc_obj $V/stb_vorbis.c
cc_obj $V/ogg/src/bitwise.c -I$V/ogg/include
cc_obj $V/ogg/src/framing.c -I$V/ogg/include
for s in $V/opusfile/src/opusfile.c $V/opusfile/src/info.c \
         $V/opusfile/src/internal.c $V/opusfile/src/stream.c; do
    cc_obj "$s" $OFINC
done
# libopus pur-C : celt + silk + silk/float + src (demos exclus)
for s in $V/opus/celt/*.c $V/opus/silk/*.c $V/opus/silk/float/*.c; do
    case "$(basename $s)" in *_demo.c|*_demo) continue;; esac
    cc_obj "$s" $OPDEF $OPINC
done
for s in $V/opus/src/*.c; do
    case "$(basename $s)" in
        *_demo.c|opus_compare.c) continue;;
    esac
    cc_obj "$s" $OPDEF $OPINC
done

# --- zig --------------------------------------------------------------------
$ZIG build-exe \
    --dep klaxon --dep ph_runtime \
    -Mroot=vehicoule/main.zig \
    -Mklaxon=klaxon/src/klaxon.zig \
    -Mph_runtime=pluginhost/src/runtime.zig \
    -O fast \
    $GOUT/kx_skia_linux.o $GOUT/kx_scenes.o $GOUT/kx_draw.o $GOUT/kx_a11y_linux.o \
    $OBJS \
    $WAMR \
    -lc \
    /usr/lib/gcc/x86_64-linux-gnu/11/libstdc++.a \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgcc_eh.a \
    /usr/lib/gcc/x86_64-linux-gnu/11/libgcc.a \
    $SKIA/out/linux/libskia.a $SKIA/out/linux/libskparagraph.a \
    $SKIA/out/linux/libskshaper.a $SKIA/out/linux/libskunicode_icu.a \
    $SKIA/out/linux/libskunicode_core.a $SKIA/out/linux/libicu.a \
    $SKIA/out/linux/libharfbuzz.a $SKIA/out/linux/libfreetype2.a \
    $SKIA/out/linux/libpng.a $SKIA/out/linux/libzlib.a \
    -L$SDL -lSDL3 -lEGL -lGL -lvulkan -lpthread -ldl -lm \
    -femit-bin=$OUT/vehicoule
echo "==> $OUT/vehicoule"
