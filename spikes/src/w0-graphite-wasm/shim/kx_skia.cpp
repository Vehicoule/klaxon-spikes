// kx_skia.cpp — implémentation W0 de l'ABI déclarée dans kx_skia.h.
// Skia wasm : Graphite-WebGPU (emdawnwebgpu), Ganesh-WebGL2, raster.
// Pas d'ASYNCIFY : le tick = wgpuInstanceProcessEvents (draine les évènements
// AllowProcessEvents prêts) ; les callbacks AllowSpontaneous sont résolus
// par tours de boucle navigateur → readback piloté en rAF.
#include "kx_skia.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"
#include "include/gpu/graphite/dawn/DawnGraphiteTypes.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/ports/SkFontMgr_empty.h"
#include "src/ports/SkFontMgr_custom.h"
#include "src/ports/SkTypeface_FreeType.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <emscripten.h>
#include <emscripten/html5_webgl.h>
#include <webgpu/webgpu_cpp.h>

#include <chrono>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <algorithm>

#include "kx_internal.h"

using skgpu::Mipmapped;
using skgpu::Protected;
using skgpu::Renderable;
using skgpu::graphite::BackendTexture;
namespace BackendTextures = skgpu::graphite::BackendTextures;
using skgpu::graphite::Context;
using skgpu::graphite::DawnBackendContext;
using skgpu::graphite::Recorder;

// ---------------------------------------------------------------------------
// Fontes
// ---------------------------------------------------------------------------
// FontMgr indexant par famille les faces chargées via kx_fonts_add — contrairement
// à SkFontMgr_New_Custom_Empty, dont makeFromData n'enregistre pas les faces dans
// l'index (matchFamily("Roboto") échoue → 0 glyphe). Nécessaire au fallback
// multi-scripts des paragraphes.
class KxFontMgr final : public SkFontMgr {
public:
    sk_sp<SkTypeface> addFromData(sk_sp<SkData> data, int idx) {
        auto tf = onMakeFromData(std::move(data), idx);
        if (tf) addFace(tf);
        return tf;
    }
    void addFace(sk_sp<SkTypeface> tf) {
        SkString name;
        tf->getFamilyName(&name);
        for (auto& s : fSets) {
            if (s->getFamilyName().equals(name)) {
                s->appendTypeface(std::move(tf));
                return;
            }
        }
        auto s = sk_make_sp<SkFontStyleSet_Custom>(name);
        s->appendTypeface(std::move(tf));
        fSets.push_back(std::move(s));
    }

protected:
    int onCountFamilies() const override { return (int)fSets.size(); }
    void onGetFamilyName(int index, SkString* name) const override {
        name->set(fSets[index]->getFamilyName());
    }
    sk_sp<SkFontStyleSet> onCreateStyleSet(int index) const override {
        return fSets[index];
    }
    sk_sp<SkFontStyleSet> onMatchFamily(const char name[]) const override {
        for (auto& s : fSets)
            if (s->getFamilyName().equals(name)) return s;
        return nullptr;
    }
    sk_sp<SkTypeface> onMatchFamilyStyle(const char name[],
                                         const SkFontStyle& style) const override {
        auto set = onMatchFamily(name);
        if (!set && !fSets.empty()) set = fSets.front();
        return set ? set->matchStyle(style) : nullptr;
    }
    sk_sp<SkTypeface> onMatchFamilyStyleCharacter(const char name[],
                                                  const SkFontStyle& style,
                                                  const char*[], int,
                                                  SkUnichar ch) const override {
        // famille demandée d'abord, puis fallback par couverture du caractère
        if (auto set = onMatchFamily(name)) {
            auto tf = set->matchStyle(style);
            if (tf && tf->unicharToGlyph(ch)) return tf;
        }
        for (auto& s : fSets) {
            auto tf = s->matchStyle(style);
            if (tf && tf->unicharToGlyph(ch)) return tf;
        }
        return onMatchFamilyStyle(name, style);
    }
    sk_sp<SkTypeface> onMakeFromData(sk_sp<SkData> data, int idx) const override {
        return SkTypeface_FreeType::MakeFromStream(
                std::make_unique<SkMemoryStream>(std::move(data)),
                SkFontArguments().setCollectionIndex(idx));
    }
    sk_sp<SkTypeface> onMakeFromStreamIndex(std::unique_ptr<SkStreamAsset> st,
                                            int idx) const override {
        return SkTypeface_FreeType::MakeFromStream(
                std::move(st), SkFontArguments().setCollectionIndex(idx));
    }
    sk_sp<SkTypeface> onMakeFromStreamArgs(std::unique_ptr<SkStreamAsset> st,
                                           const SkFontArguments& a) const override {
        return SkTypeface_FreeType::MakeFromStream(std::move(st), a);
    }
    sk_sp<SkTypeface> onMakeFromFile(const char path[], int idx) const override {
        return SkTypeface_FreeType::MakeFromStream(
                SkStream::MakeFromFile(path),
                SkFontArguments().setCollectionIndex(idx));
    }
    sk_sp<SkTypeface> onLegacyMakeTypeface(const char name[],
                                           SkFontStyle style) const override {
        return onMatchFamilyStyle(name, style);
    }

private:
    std::vector<sk_sp<SkFontStyleSet_Custom>> fSets;
};

struct kx_fonts {
    KxFontMgr* mgr = new KxFontMgr();
    sk_sp<SkFontMgr> mgr_ref = sk_ref_sp(mgr);
    std::vector<sk_sp<SkTypeface>> faces;
    std::vector<SkString> families;
    sk_sp<skia::textlayout::FontCollection> collection;
    bool dirty = true;

    skia::textlayout::FontCollection* get() {
        if (dirty || !collection) {
            collection = sk_make_sp<skia::textlayout::FontCollection>();
            collection->setDefaultFontManager(mgr_ref);
            dirty = false;
        }
        return collection.get();
    }
};

skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts* f) {
    return f ? f->get() : nullptr;
}

const std::vector<SkString>* kx_fonts_families(kx_fonts* f) {
    return f ? &f->families : nullptr;
}

static kx_fonts g_fonts;
kx_fonts* kx_fonts_global() { return &g_fonts; }
kx_fonts* kx_fonts_create() { return new kx_fonts(); }

int kx_fonts_add(kx_fonts* f, const void* data, size_t len) {
    if (!f || !data || !len) return -1;
    auto d = SkData::MakeWithCopy(data, len);
    int added = -1;
    for (int i = 0; i < 16; ++i) {  // TTC : énumère jusqu'à échec
        sk_sp<SkTypeface> tf = f->mgr->addFromData(d, i);
        if (!tf) break;
        f->faces.push_back(tf);
        SkString fam;
        tf->getFamilyName(&fam);
        f->families.push_back(fam);
        if (added < 0) added = (int)f->faces.size() - 1;
    }
    f->dirty = true;
    return added;
}

int kx_fonts_count(const kx_fonts* f) { return f ? (int)f->faces.size() : 0; }

int kx_fonts_family_index(const kx_fonts* f, const char* name) {
    if (!f || !name) return -1;
    for (size_t i = 0; i < f->families.size(); ++i)
        if (f->families[i].equals(name)) return (int)i;
    return -1;
}

// Scan récursif .ttf/.otf/.ttc (emscripten FS — fichiers préloadés ou
// NODERAWFS). Parité ABI avec le natif ; -1 si path null.
#include <dirent.h>
#include <sys/stat.h>
static int fonts_add_dir_rec(kx_fonts* f, const std::string& dir, int depth) {
    if (depth > 6) return 0;
    DIR* d = opendir(dir.c_str());
    if (!d) return 0;
    std::vector<std::string> files, subs;
    struct dirent* e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        std::string path = dir + "/" + e->d_name;
        struct stat st;
        if (stat(path.c_str(), &st)) continue;
        if (S_ISDIR(st.st_mode)) { subs.push_back(path); continue; }
        if (!S_ISREG(st.st_mode)) continue;
        size_t n = strlen(e->d_name);
        if (n < 4) continue;
        std::string ext = e->d_name + n - 4;
        for (auto& c : ext) c = (char)tolower(c);
        if (ext == ".ttf" || ext == ".otf" || ext == ".ttc")
            files.push_back(path);
    }
    closedir(d);
    std::sort(files.begin(), files.end());
    std::sort(subs.begin(), subs.end());
    int added = 0;
    for (auto& p : files) {
        sk_sp<SkData> data = SkData::MakeFromFileName(p.c_str());
        if (data && kx_fonts_add(f, data->data(), data->size()) >= 0) added++;
    }
    for (auto& sub : subs) added += fonts_add_dir_rec(f, sub, depth + 1);
    return added;
}
int kx_fonts_add_dir(kx_fonts* f, const char* path) {
    if (!f || !path) return -1;
    return fonts_add_dir_rec(f, path, 0);
}
void kx_fonts_free(kx_fonts* f) { delete f; }

// ---------------------------------------------------------------------------
// Contextes
// ---------------------------------------------------------------------------
struct kx_ctx {
    kx_backend backend = KX_BACKEND_RASTER;
    std::string driver_info;

    // Raster : rien.
    // Ganesh
    sk_sp<GrDirectContext> gr;
    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE gl_handle = 0;
    // Graphite
    wgpu::Instance instance;
    wgpu::Device device;
    wgpu::Queue queue;
    std::unique_ptr<Context> gctx;
    std::unique_ptr<Recorder> recorder;
    sk_sp<SkImage> corpus_img;
};

// Config wasm upstream (non-yielding) : pas de tick → useAsyncPipelineCreation=false,
// allowCpuSync=false, allowScopedErrorChecks=false (requis : CreateRenderPipelineAsync
// est interdit en wasm et busyWait ne peut pas attendre les callbacks AllowSpontaneous
// qui exigent un tour de boucle navigateur). La complétion est sondée via rAF +
// checkAsyncWorkCompletion().
kx_ctx* kx_ctx_create_graphite_webgpu() {
    auto* c = new kx_ctx();
    c->instance = wgpu::CreateInstance();
    WGPUDevice raw = emscripten_webgpu_get_device();
    if (!raw) { delete c; return nullptr; }
    c->device = wgpu::Device::Acquire(raw);
    c->queue = c->device.GetQueue();

    DawnBackendContext bc;
    bc.fInstance = c->instance;
    bc.fDevice = c->device;
    bc.fQueue = c->queue;
    bc.fTick = nullptr;  // non-yielding : la config wasm requise (cf. commentaire ci-dessus)
    c->gctx = skgpu::graphite::ContextFactory::MakeDawn(bc, {});
    if (!c->gctx) { delete c; return nullptr; }
    c->recorder = c->gctx->makeRecorder();
    c->backend = KX_BACKEND_GRAPHITE_WEBGPU;
    c->driver_info = "graphite-webgpu(emdawnwebgpu;adapter=browser)";
    return c;
}

kx_ctx* kx_ctx_create_ganesh_webgl(const char* canvas_selector) {
    auto* c = new kx_ctx();
    EmscriptenWebGLContextAttributes attrs;
    emscripten_webgl_init_context_attributes(&attrs);
    attrs.majorVersion = 2;
    attrs.minorVersion = 0;
    attrs.alpha = EM_TRUE;
    const char* sel = canvas_selector ? canvas_selector : "#canvas";
    c->gl_handle = emscripten_webgl_create_context(sel, &attrs);
    if (c->gl_handle <= 0) { delete c; return nullptr; }
    if (emscripten_webgl_make_context_current(c->gl_handle) != EMSCRIPTEN_RESULT_SUCCESS) {
        emscripten_webgl_destroy_context(c->gl_handle);
        delete c; return nullptr;
    }
    auto iface = GrGLMakeAssembledWebGLInterface(
            nullptr, [](void*, const char* name) -> GrGLFuncPtr {
                return (GrGLFuncPtr)emscripten_webgl_get_proc_address(name);
            });
    if (!iface) { emscripten_webgl_destroy_context(c->gl_handle); delete c; return nullptr; }
    c->gr = GrDirectContexts::MakeGL(iface);
    if (!c->gr) { emscripten_webgl_destroy_context(c->gl_handle); delete c; return nullptr; }
    c->backend = KX_BACKEND_GANESH_WEBGL;
    c->driver_info = std::string("ganesh-webgl2(canvas=") + sel + ")";
    return c;
}

kx_ctx* kx_ctx_create_raster() {
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_RASTER;
    c->driver_info = "raster(cpu)";
    return c;
}

kx_backend kx_ctx_backend(const kx_ctx* c) { return c ? c->backend : KX_BACKEND_RASTER; }
const char* kx_ctx_driver_info(const kx_ctx* c) { return c ? c->driver_info.c_str() : "none"; }

int kx_ctx_has_unfinished_work(kx_ctx* c) {
    if (!c || !c->gctx) return 0;
    return c->gctx->hasUnfinishedGpuWork() ? 1 : 0;
}

void kx_ctx_free(kx_ctx* c) {
    if (!c) return;
    c->corpus_img.reset();
    c->recorder.reset();
    c->gctx.reset();
    c->gr.reset();
    if (c->gl_handle > 0) emscripten_webgl_destroy_context(c->gl_handle);
    c->device = nullptr;
    c->queue = nullptr;
    c->instance = nullptr;
    delete c;
}

// ---------------------------------------------------------------------------
// Cibles (struct définie dans kx_internal.h)
// ---------------------------------------------------------------------------

kx_target* kx_target_offscreen(kx_ctx* c, int w, int h) {
    if (!c || w <= 0 || h <= 0) return nullptr;
    auto* t = new kx_target();
    t->ctx = c; t->w = w; t->h = h;
    SkImageInfo ii = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType,
                                       kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    switch (c->backend) {
        case KX_BACKEND_RASTER:
            t->surface = SkSurfaces::Raster(ii);
            break;
        case KX_BACKEND_GANESH_WEBGL:
            t->surface = SkSurfaces::RenderTarget(c->gr.get(), skgpu::Budgeted::kYes,
                                                  ii, 0, kTopLeft_GrSurfaceOrigin, nullptr);
            break;
        case KX_BACKEND_GRAPHITE_WEBGPU:
            t->surface = SkSurfaces::RenderTarget(c->recorder.get(), ii);
            break;
        default: break;
    }
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

kx_target* kx_target_canvas(kx_ctx* c, const char* sel, int w, int h) {
    if (!c || !sel) return nullptr;
    if (c->backend == KX_BACKEND_GRAPHITE_WEBGPU) {
        auto* t = new kx_target();
        t->ctx = c; t->w = w; t->h = h; t->onscreen = true;
        wgpu::EmscriptenSurfaceSourceCanvasHTMLSelector src;
        src.selector = sel;
        wgpu::SurfaceDescriptor sd;
        sd.nextInChain = &src;
        t->wgpu_surface = c->instance.CreateSurface(&sd);
        wgpu::SurfaceConfiguration cfg = {};
        cfg.device = c->device;
        cfg.format = wgpu::TextureFormat::BGRA8Unorm;
        cfg.usage = wgpu::TextureUsage::RenderAttachment;
        cfg.width = (uint32_t)w;
        cfg.height = (uint32_t)h;
        cfg.presentMode = wgpu::PresentMode::Fifo;
        cfg.alphaMode = wgpu::CompositeAlphaMode::Premultiplied;
        t->wgpu_surface.Configure(&cfg);
        return t;
    }
    if (c->backend == KX_BACKEND_GANESH_WEBGL) {
        // Dessiner directement dans le FBO 0 du canvas WebGL.
        auto* t = new kx_target();
        t->ctx = c; t->w = w; t->h = h; t->onscreen = true;
        GrGLFramebufferInfo fbi;
        fbi.fFBOID = 0;
        fbi.fFormat = 0x8058;  // GL_RGBA8
        GrBackendRenderTarget rt = GrBackendRenderTargets::MakeGL(w, h, 0, 0, fbi);
        SkImageInfo ii = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType,
                                           kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
        t->surface = SkSurfaces::WrapBackendRenderTarget(
                c->gr.get(), rt, kBottomLeft_GrSurfaceOrigin,
                kRGBA_8888_SkColorType, SkColorSpace::MakeSRGB(), nullptr);
        if (!t->surface) { delete t; return nullptr; }
        return t;
    }
    return nullptr;
}

void kx_target_free(kx_target* t) {
    if (!t) return;
    t->surface.reset();
    t->wgpu_tex = nullptr;
    t->wgpu_surface = nullptr;
    delete t;
}

void kx_target_size(const kx_target* t, int* w, int* h) {
    if (w) *w = t ? t->w : 0;
    if (h) *h = t ? t->h : 0;
}

// Soumet le contenu enregistré (graphite) ou flush (ganesh). Interne + présent.
int kx_flush_target(kx_ctx* c, kx_target* t) {
    if (!t || !c) return -1;
    if (c->backend == KX_BACKEND_GRAPHITE_WEBGPU) {
        if (t->dirty) {
            if (auto rec = c->recorder->snap()) {
                skgpu::graphite::InsertRecordingInfo info = {};
                info.fRecording = rec.get();
                if (c->gctx->insertRecording(info) !=
                    skgpu::graphite::InsertStatus::kSuccess) {
                    return -2;
                }
                c->gctx->submit();
            }
            t->dirty = false;
        }
        return 0;
    }
    if (c->backend == KX_BACKEND_GANESH_WEBGL) {
        c->gr->flushAndSubmit();
        t->dirty = false;
        return 0;
    }
    t->dirty = false;
    return 0;
}

// Prépare la surface canvas graphite pour une nouvelle frame (GetCurrentTexture
// + WrapBackendTexture). Appelé automatiquement par kx_scene_draw sur cible canvas.
int kx_graphite_canvas_acquire(kx_target* t) {
    kx_ctx* c = t->ctx;
    wgpu::SurfaceTexture st;
    t->wgpu_surface.GetCurrentTexture(&st);
    if (st.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessOptimal &&
        st.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal) {
        return -1;
    }
    t->wgpu_tex = st.texture;  // SurfaceTexture.texture est déjà un wgpu::Texture
    BackendTexture bt = BackendTextures::MakeDawn(t->wgpu_tex.Get());
    t->surface = SkSurfaces::WrapBackendTexture(
            c->recorder.get(), bt, SkColorSpace::MakeSRGB(), nullptr);
    return t->surface ? 0 : -2;
}

// Hook canonique : pour cible onscreen graphite sans surface, acquire canvas.
int kx_acquire_surface(kx_target* t) {
    if (!t || !t->onscreen || t->surface) return 0;
    kx_ctx* c = t->ctx;
    if (c->backend == KX_BACKEND_GRAPHITE_WEBGPU) return kx_graphite_canvas_acquire(t);
    return 0;  // ganesh/raster : surfaces posées à la création
}

int kx_present(kx_ctx* c, kx_target* t) {
    if (!c || !t || !t->onscreen) return -1;
    int rc = kx_flush_target(c, t);
    if (rc) return rc;
    if (c->backend == KX_BACKEND_GRAPHITE_WEBGPU) {
        t->wgpu_surface.Present();
        t->wgpu_tex = nullptr;
        t->surface.reset();  // la texture est consommée : re-acquise à la frame suivante
        return 0;
    }
    // Ganesh : le FBO0 a été flushé → présenté implicitement à la fin du task.
    return 0;
}

// ---------------------------------------------------------------------------
// Readback
// ---------------------------------------------------------------------------
struct kx_readback {
    kx_ctx* ctx = nullptr;
    sk_sp<SkSurface> keep_alive;      // la surface lue doit survivre
    int w = 0, h = 0;
    int state = 0;                    // 0 en attente, 1 prêt, -1 échec
    std::unique_ptr<const SkImage::AsyncReadResult> result;
    std::vector<uint8_t> pixels;      // raster/ganesh : pixels synchrones
};

static void kx_on_read(SkImage::ReadPixelsContext vctx,
                       std::unique_ptr<const SkImage::AsyncReadResult> res) {
    auto* rb = static_cast<kx_readback*>(vctx);
    rb->result = std::move(res);
    rb->state = rb->result ? 1 : -1;
}

kx_readback* kx_readback_start(kx_ctx* c, kx_target* t) {
    if (!c || !t) return nullptr;
    auto* rb = new kx_readback();
    rb->ctx = c; rb->w = t->w; rb->h = t->h; rb->keep_alive = t->surface;
    SkImageInfo dst = SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                      kUnpremul_SkAlphaType, SkColorSpace::MakeSRGB());
    if (c->backend == KX_BACKEND_GRAPHITE_WEBGPU) {
        if (kx_flush_target(c, t)) { delete rb; return nullptr; }
        c->gctx->asyncRescaleAndReadPixels(
                t->surface.get(), dst, SkIRect::MakeWH(t->w, t->h),
                SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                &kx_on_read, rb);
        // submit() lance le readback ; la complétion est sondée par rAF.
        c->gctx->submit();
        c->gctx->checkAsyncWorkCompletion();
        return rb;
    }
    // Raster & Ganesh : lecture synchrone immédiate.
    kx_flush_target(c, t);
    rb->pixels.resize((size_t)t->w * t->h * 4);
    SkPixmap out(dst, rb->pixels.data(), (size_t)t->w * 4);
    if (!t->surface->readPixels(out, 0, 0)) { delete rb; return nullptr; }
    rb->state = 1;
    return rb;
}

int kx_readback_poll(kx_ctx* c, kx_readback* rb) {
    if (!rb) return -1;
    if (rb->state != 0) return rb->state;
    if (c && c->gctx) {
        c->gctx->submit();
        c->gctx->checkAsyncWorkCompletion();
    }
    return rb->state;
}

int kx_readback_copy(const kx_readback* rb, uint8_t* dst) {
    if (!rb || rb->state != 1 || !dst) return -1;
    size_t bytes = (size_t)rb->w * rb->h * 4;
    if (rb->result) {
        if (rb->result->count() != 1) return -2;
        size_t src_rb = rb->result->rowBytes(0);
        const uint8_t* src = static_cast<const uint8_t*>(rb->result->data(0));
        if (!src) return -3;
        for (int y = 0; y < rb->h; ++y)
            memcpy(dst + (size_t)y * rb->w * 4, src + (size_t)y * src_rb, (size_t)rb->w * 4);
        return (int)bytes;
    }
    if ((int)rb->pixels.size() < (int)bytes) return -4;
    memcpy(dst, rb->pixels.data(), bytes);
    return (int)bytes;
}

void kx_readback_free(kx_readback* rb) { delete rb; }

// ---------------------------------------------------------------------------
// Bench : temps CPU record + submit (métrique du corpus)
// ---------------------------------------------------------------------------
// Image 64×64 partagée — produite en raster puis convertie en texture backend.
// Retourne toujours une SkImage dessinable par le backend du ctx (ou nullptr).
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx* c) {
    if (!c) return nullptr;
    if (!c->corpus_img) {
        const int n = 64;
        SkImageInfo ii = SkImageInfo::Make(n, n, kRGBA_8888_SkColorType,
                                         kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
        std::vector<uint32_t> px((size_t)n * n);
        for (int y = 0; y < n; ++y)
            for (int x = 0; x < n; ++x) {
                bool odd = ((x / 8) + (y / 8)) & 1;
                SkColor col = odd ? SkColorSetARGB(255, 40 + x * 3, 160, 255 - y * 3)
                                  : SkColorSetARGB(255, 200, 60 + y * 2, 90);
                px[y * n + x] = col;
            }
        sk_sp<SkImage> raster = SkImages::RasterFromData(
                ii, SkData::MakeWithCopy(px.data(), px.size() * 4), n * 4);
        switch (c->backend) {
            case KX_BACKEND_GRAPHITE_WEBGPU:
                c->corpus_img = SkImages::TextureFromImage(
                        c->recorder.get(), raster.get(), {});
                break;
            default:
                c->corpus_img = std::move(raster);
                break;
        }
    }
    return c->corpus_img;
}

double kx_bench_ms(kx_ctx* c, kx_fonts* f, kx_target* t, int scene, int iters) {
    if (!c || !t || iters <= 0) return -1.0;
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        double phase = (double)(i % 60) / 60.0;
        if (kx_scene_draw(c, f, t, scene, phase)) return -2.0;
    }
    kx_flush_target(c, t);
    auto t1 = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// ---------------------------------------------------------------------------
// Accesseurs pour kx_draw.cpp (API v1)
// ---------------------------------------------------------------------------
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx* c) {
    return (c && c->backend == KX_BACKEND_GRAPHITE_WEBGPU) ? c->recorder.get() : nullptr;
}

GrDirectContext* kx_ctx_gr_context(kx_ctx* c) {
    return (c && c->backend == KX_BACKEND_GANESH_WEBGL) ? c->gr.get() : nullptr;
}
