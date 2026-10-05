#!/bin/bash
# build_k3.sh — compile la gallery canonique (zig 0.17, x86_64-linux-android) + APK gradle.
# Sources : app/jni/src/zig/gallery/main.zig (+ module klaxon/ + DejaVuSans.ttf embarquée)
#           app/jni/src/kx/kx_skia_android.cpp (platform file ganesh-gles canonique)
#           app/jni/src/kx/kx_draw.cpp + kx_scenes.cpp (canoniques, inchangés)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJ=android-project
SRC="$PROJ/app/jni/src"
ZIG="${ZIG:-$HOME/kx/tools/zig-x86_64-linux-0.17.0/zig}"
export KX_SKIA_OUT="${KX_SKIA_OUT:-$HOME/kx/deps/skia/out/android-x64}"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

echo "[zig] gallery/main.zig -> gallery.o (x86_64-linux-android.31, klaxon module)"
"$ZIG" build-obj -O ReleaseFast -fPIC -lc -fno-stack-check \
    -target x86_64-linux-android.31 \
    --dep klaxon \
    -Mroot="$SRC/zig/gallery/main.zig" \
    -Mklaxon="$SRC/zig/klaxon/klaxon.zig" \
    --name gallery \
    -femit-bin="$SRC/gallery.o" 2>&1 | sed 's/^/[zig] /'
ls -la "$SRC/gallery.o"

echo "[gradle] assembleDebug (KX_SKIA_OUT=$KX_SKIA_OUT)"
cd "$PROJ"
./gradlew -PBUILD_WITH_CMAKE :app:assembleDebug --console=plain -q 2>&1 | tail -25
ls -la app/build/outputs/apk/debug/app-debug.apk
