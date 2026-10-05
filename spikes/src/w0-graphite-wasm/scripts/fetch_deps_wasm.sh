#!/usr/bin/env bash
# Fetch the minimal Skia third_party/externals needed for the wasm build.
# Pins come from skia's DEPS at 8643b1d64cff21b5e6f8d65ca98204c6eecb0098.
set -euo pipefail
SKIA=/home/ubuntu/work/Klaxon/spikes/w0-graphite-wasm/deps/skia
EXT=$SKIA/third_party/externals
mkdir -p "$EXT"

fetch() { # name url sha
  local name=$1 url=$2 sha=$3
  local dir="$EXT/$name"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    echo "== $name already at $sha"; return 0
  fi
  rm -rf "$dir"; mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url" 2>/dev/null || true
  echo "== fetching $name"
  git -C "$dir" fetch -q --depth=1 origin "$sha"
  git -C "$dir" checkout -q FETCH_HEAD
  echo "== $name -> $(git -C "$dir" rev-parse --short HEAD)"
}

CHROMIUM=https://chromium.googlesource.com
SKIA_GOOG=https://skia.googlesource.com

fetch freetype        $CHROMIUM/chromium/src/third_party/freetype2.git        264b5fbf5b912b39f98d038bf75d39be0a73f21b
fetch harfbuzz        $CHROMIUM/external/github.com/harfbuzz/harfbuzz.git      9cb1fee51069b206effb4736e443b038d230789d
fetch icu             $CHROMIUM/chromium/deps/icu.git                         d578f2e8b7bd5938e21cfb6bf15c079e0aa5b738
fetch libpng          $SKIA_GOOG/third_party/libpng.git                       d5515b5b8be3901aac04e5bd8bd5c89f287bcd33
fetch zlib            $CHROMIUM/chromium/src/third_party/zlib                 646b7f569718921d7d4b5b8e22572ff6c76f2596
fetch jinja2          $CHROMIUM/chromium/src/third_party/jinja2               c3027d884967773057bf74b957e3fea87e5df4d7
fetch markupsafe      $CHROMIUM/chromium/src/third_party/markupsafe           4256084ae14175d38a3ff7d739dca83ae49ccec6
fetch partition_alloc $CHROMIUM/chromium/src/base/allocator/partition_allocator.git 03cc513177b4340bee3dbfd46f6dd5fdded43b79

echo "done"
