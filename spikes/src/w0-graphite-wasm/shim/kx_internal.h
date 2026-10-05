// kx_internal.h — déclarations partagées entre kx_skia.cpp et kx_scenes.cpp.
#pragma once

#include "kx_skia.h"

#include "include/core/SkSurface.h"
#include <webgpu/webgpu_cpp.h>
#include <vector>

class GrDirectContext;
class SkString;
namespace skgpu::graphite { class Recorder; }
namespace skia::textlayout { class FontCollection; }

struct kx_ctx;   // défini dans kx_skia.cpp

struct kx_target {
    kx_ctx* ctx = nullptr;  // non possédé
    sk_sp<SkSurface> surface;
    int w = 0, h = 0;
    bool dirty = false;
    wgpu::Surface wgpu_surface;
    wgpu::Texture wgpu_tex;
    bool onscreen = false;
};

// Internes implémentés dans kx_skia.cpp.
int kx_flush_target(kx_ctx*, kx_target*);
int kx_graphite_canvas_acquire(kx_target*);
// Hook lazy-acquire (canonique) : wasm = acquire canvas graphite pour
// cibles onscreen sans surface ; no-op sinon.
int kx_acquire_surface(kx_target*);

// Image du corpus convertie en texture backend (mise en cache sur le ctx).
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx*);

// Accesseurs pour kx_draw.cpp (API v1).
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx*);
GrDirectContext* kx_ctx_gr_context(kx_ctx*);
skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts*);
const std::vector<SkString>* kx_fonts_families(kx_fonts*);
