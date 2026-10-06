#!/bin/bash
# build_veh.sh — compile vehicoule (zig 0.17, x86_64-linux-android) + APK gradle.
# V1 poche : scan natif (pas de WAMR-NDK). Décodeurs vendored compilés en cmake.
#
# Staging (depuis le repo Klaxon, à faire une fois) :
#   cp -r vehicoule               $PROJ/app/jni/src/veh
#   mkdir -p $PROJ/app/jni/src/zig/{vehicoule,klaxon,ph}
#   cp vehicoule/main.zig         $PROJ/app/jni/src/zig/vehicoule/
#   cp vehicoule/DejaVuSans.ttf   $PROJ/app/jni/src/zig/vehicoule/
#   cp klaxon/src/*.zig           $PROJ/app/jni/src/zig/klaxon/
#   cp pluginhost/src/runtime.zig $PROJ/app/jni/src/ph/          # (ph_runtime module)
#   cp platform/android/jni/*.cpp $PROJ/app/jni/src/
#   cp platform/android/CMakeLists-vehicoule.txt $PROJ/app/jni/src/CMakeLists.txt
#   cp -r vehicoule/music-test    $PROJ/app/src/main/assets/music-test  # fixtures embarquées (V1.1)
#   cp platform/android/build.gradle.kx $PROJ/app/build.gradle          # trim SDL + ARM64_ONLY (V1.2-slim)
#   patch -d $SDL3_SRC -p1 < platform/android/patches/sdl-android-hidapi-guard.patch
# puis : scripts/build_veh.sh && apksigner sign (keystore local sideload)
# ARM64_ONLY=1 ./build_veh.sh → APK arm64 seul (~12 Mo) ; défaut = dual-ABI (dev ému x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJ=android-project
SRC="$PROJ/app/jni/src"
ZIG="${ZIG:-$HOME/kx/tools/zig-x86_64-linux-0.17.0/zig}"
export KX_SKIA_OUT="${KX_SKIA_OUT:-$HOME/kx/deps/skia/out/android-x64}"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

# ReleaseSmall pour le shipping (objet 1,2 Mo vs 6,7 en ReleaseFast —
# BUILD-PROFILE.md) ; VEH_OPT=ReleaseFast pour les builds de bench.
VEH_OPT="${VEH_OPT:-ReleaseSmall}"
for spec in "x86_64-linux-android.31:vehicoule-x64.o" "aarch64-linux-android.31:vehicoule-arm64.o"; do
    tgt="${spec%%:*}"; obj="${spec##*:}"
    echo "[zig] vehicoule/main.zig -> $obj ($tgt, $VEH_OPT)"
    "$ZIG" build-obj -O "$VEH_OPT" -fPIC -lc -fno-stack-check \
        -target "$tgt" \
        --dep klaxon --dep ph_runtime \
        -Mroot="$SRC/zig/vehicoule/main.zig" \
        -Mklaxon="$SRC/zig/klaxon/klaxon.zig" \
        -Mph_runtime="$SRC/ph/runtime.zig" \
        --name vehicoule \
        -femit-bin="$SRC/$obj" 2>&1 | sed 's/^/[zig] /'
    ls -la "$SRC/$obj"
done

echo "[gradle] assembleDebug (KX_SKIA_OUT=$KX_SKIA_OUT, ARM64_ONLY=${ARM64_ONLY:-0})"
cd "$PROJ"
EXTRA_PROPS=()
if [ "${ARM64_ONLY:-0}" = "1" ]; then EXTRA_PROPS+=(-PARM64_ONLY); fi
./gradlew -PBUILD_WITH_CMAKE "${EXTRA_PROPS[@]}" :app:assembleDebug --console=plain -q 2>&1 | tail -25
ls -la app/build/outputs/apk/debug/app-debug.apk
