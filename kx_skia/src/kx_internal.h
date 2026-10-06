// kx_internal.h — variantes nativas : déclarations partagées entre
// kx_skia_linux.cpp et kx_scenes.cpp. Même disposition que la version wasm
// pour que les offsets de kx_target concordent entre les deux .o.
#pragma once

#include "kx_skia.h"

#include <cstdint>
#include <vector>
#include "include/core/SkSurface.h"
#include "include/core/SkImage.h"

struct kx_ctx;   // défini dans kx_skia_linux.cpp / kx_skia_win.cpp (platform file)
class GrDirectContext;
class SkString;

// Swapchain Dawn onscreen (Windows) — définie dans kx_skia_win.cpp.
struct kx_dawn_surface;

// Image swapchain graphite-vulkan (android) : surface pré-wrapée +
// semaphore de fin de rendu persistant (réutilisé à chaque acquire de
// cette image — consommé par le present).
struct kx_vkimg {
    sk_sp<SkSurface> surf;
    uint64_t render_sem = 0; // VkSemaphore
};

struct kx_target {
    kx_ctx* ctx = nullptr;  // non possédé
    sk_sp<SkSurface> surface;
    int w = 0, h = 0;
    bool dirty = false;
    bool onscreen = false;
    // ganesh GL natif (FBO/RBO possédés — linux/macos offscreen/fbo0).
    unsigned int gl_fbo = 0;
    unsigned int gl_rb = 0;
    // onscreen graphite-metal : CAMetalLayer + drawable courant retenus.
    void* mtl_layer = nullptr;
    void* mtl_drawable = nullptr;
    // onscreen Dawn (Windows) : swapchain WebGPU par HWND ; surface Skia
    // réacquise par frame, libérée après Present.
    kx_dawn_surface* dawn = nullptr;
    // onscreen graphite-vulkan (android) : swapchain + images ; surface
    // active posée à l'acquire, reset après present. VkSurfaceKHR et
    // VkDevice possédés par le ctx — pas par la cible.
    uint64_t vk_swapchain = 0; // VkSwapchainKHR
    std::vector<kx_vkimg> vk_imgs;
    uint32_t vk_img_idx = 0;
    uint64_t vk_acquire_sem = 0; // VkSemaphore signalé par l'Acquire courant
    // instrumentation frame-breakdown (KX_VK_DEBUG / debug.kx.vk / fichier
    // marqueur) : temps CPU en ns par phase, log toutes les 120 frames.
    uint64_t vk_dbg_frames = 0;
    uint64_t vk_dbg_acq_ns = 0;   // vkAcquireNextImageKHR (blocage vsync+GPU)
    uint64_t vk_dbg_rec_ns = 0;   // acquire→present = dessin zig + record skia
    uint64_t vk_dbg_sub_ns = 0;   // insertRecording + submit
    uint64_t vk_dbg_pres_ns = 0;  // vkQueuePresentKHR
    uint64_t vk_dbg_acq_end = 0;  // timestamp fin d'acquire (origine record)
};

// Internes implémentés dans kx_skia_linux.cpp.
int kx_flush_target(kx_ctx*, kx_target*);
int kx_graphite_canvas_acquire(kx_target*);   // stub : webgpu seulement en wasm
/// Acquisition paresseuse de la surface onscreen au 1er dessin (metal :
/// nextDrawable → WrapBackendTexture ; autres backends : no-op, surface
/// déjà posée à la création de la cible).
int kx_acquire_surface(kx_target*);
int kx_metal_acquire(kx_target*);   // impl macOS (stub -1 ailleurs)
int kx_metal_present(kx_target*);
// Canvas prêt à dessiner (fait l'acquisition onscreen si besoin).
SkCanvas* kx_target_canvas_ready(kx_target*);

// Pont ObjC++ (kx_metal.mm) — types void* = CFTypeRef, gestion manuelle.
extern "C" {
void* kx_mtl_create_device(void);
void* kx_mtl_create_queue(void* device);
const char* kx_mtl_device_name(void* device);
void* kx_mtl_retain(void* obj);
void kx_mtl_release(void* obj);
void* kx_mtl_layer_configure(void* layer, void* device, double w, double h,
                             double scale);
void* kx_mtl_layer_next_drawable(void* layer);
void* kx_mtl_drawable_texture(void* drawable);
void kx_mtl_present_drawable(void* queue, void* drawable);
}

// Image du corpus convertie en texture backend (mise en cache sur le ctx).
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx*);

// kx_draw v1 : accès internes backend-agnostiques.
namespace skgpu::graphite { class Recorder; }
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx*);  // nullptr hors graphite
GrDirectContext* kx_ctx_gr_context(kx_ctx*);                   // nullptr hors ganesh
namespace skia::textlayout { class FontCollection; }
skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts*);
const std::vector<SkString>* kx_fonts_families(kx_fonts*);
