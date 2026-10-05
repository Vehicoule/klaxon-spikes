// kx_skia.cpp — implémentation native Windows x64 de l'ABI kx_skia (K0).
// Backends : raster CPU, ganesh GL (WGL), graphite Dawn (D3D12 / Vulkan).
// Pas de présentation onscreen en K0 : cibles offscreen + readback synchrone
// (SyncToCpu::kYes autorisé en natif via DawnNativeProcessEventsFunction).

#include "kx_skia.h"
#include "kx_internal.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/ports/SkFontMgr_empty.h"
#include "include/encode/SkPngEncoder.h"

#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/win/GrGLMakeWinInterface.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLFunctions.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/SkImageGanesh.h"

#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"
#include "include/gpu/graphite/dawn/DawnGraphiteTypes.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Image.h"
#include "src/gpu/graphite/ContextOptionsPriv.h"

#include "dawn/native/DawnNative.h"
#include "dawn/dawn_proc.h"
#include "webgpu/webgpu_cpp.h"

#include "modules/skparagraph/include/FontCollection.h"

#include <windows.h>
#include <GL/gl.h>

// WGL_ARB_create_context (wglext.h n'est pas dans le SDK Windows ; constantes
// du registre Khronos, identiques partout).
#define WGL_CONTEXT_MAJOR_VERSION_ARB 0x2091
#define WGL_CONTEXT_MINOR_VERSION_ARB 0x2092
#define WGL_CONTEXT_PROFILE_MASK_ARB  0x9126
#define WGL_CONTEXT_CORE_PROFILE_BIT_ARB 0x00000001
typedef HGLRC (WINAPI* PFNWGLCREATECONTEXTATTRIBSARBPROC)(HDC, HGLRC, const int*);

using namespace skgpu;

// ---------------------------------------------------------------------------
// Fonts : KxFontMgr maison (leçon W0 #5 : makeFromData du Custom_Empty n'indexe
// pas les faces par famille ni par couverture).
// ---------------------------------------------------------------------------
class KxFontMgr : public SkFontMgr {
public:
    KxFontMgr() : fDelegate(SkFontMgr_New_Custom_Empty()) {}

    // Ajoute une face (TTF/OTF/TTC — chaque face du TTC). Retourne nb faces.
    int add(sk_sp<SkData> data) {
        int added = 0;
        // Essaye chaque index de la collection jusqu'à échec.
        for (int i = 0; i < 8; ++i) {
            sk_sp<SkTypeface> tf = fDelegate->makeFromData(data, i);
            if (!tf) break;
            SkString name;
            tf->getFamilyName(&name);
            fFaces.push_back(tf);
            fFamilies.push_back(name);
            ++added;
        }
        return added;
    }

    int faceCount() const { return (int)fFaces.size(); }
    const std::vector<SkString>& families() const { return fFamilies; }

protected:
    int onCountFamilies() const override { return (int)fFamilies.size(); }
    void onGetFamilyName(int index, SkString* name) const override {
        *name = fFamilies[index];
    }
    sk_sp<SkFontStyleSet> onCreateStyleSet(int index) const override {
        return nullptr;  // inutilisé par skparagraph (matchTypeface passe par MatchFamilyStyle)
    }
    sk_sp<SkFontStyleSet> onMatchFamily(const char[]) const override {
        return nullptr;
    }
    sk_sp<SkTypeface> onMatchFamilyStyle(const char familyName[],
                                         const SkFontStyle&) const override {
        for (size_t i = 0; i < fFamilies.size(); ++i) {
            if (!strcmp(fFamilies[i].c_str(), familyName)) return fFaces[i];
        }
        return fFaces.empty() ? nullptr : fFaces.front();
    }
    sk_sp<SkTypeface> onMatchFamilyStyleCharacter(const char familyName[],
                                                  const SkFontStyle&,
                                                  const char*[], int,
                                                  SkUnichar ch) const override {
        // D'abord la famille demandée, puis n'importe quelle face couvrant.
        for (size_t i = 0; i < fFaces.size(); ++i) {
            if (familyName && !strcmp(fFamilies[i].c_str(), familyName) &&
                fFaces[i]->unicharToGlyph(ch) != 0)
                return fFaces[i];
        }
        for (const auto& f : fFaces) {
            if (f->unicharToGlyph(ch) != 0) return f;
        }
        return nullptr;
    }
    sk_sp<SkTypeface> onMakeFromData(sk_sp<SkData> data, int ttc) const override {
        return fDelegate->makeFromData(std::move(data), ttc);
    }
    sk_sp<SkTypeface> onMakeFromStreamIndex(std::unique_ptr<SkStreamAsset> s,
                                          int ttc) const override {
        return fDelegate->makeFromStream(std::move(s), ttc);
    }
    sk_sp<SkTypeface> onMakeFromStreamArgs(std::unique_ptr<SkStreamAsset> s,
                                         const SkFontArguments& a) const override {
        return fDelegate->makeFromStream(std::move(s), a);
    }
    sk_sp<SkTypeface> onMakeFromFile(const char path[], int ttc) const override {
        return fDelegate->makeFromFile(path, ttc);
    }
    sk_sp<SkTypeface> onLegacyMakeTypeface(const char familyName[],
                                         SkFontStyle st) const override {
        return fDelegate->legacyMakeTypeface(familyName, st);
    }

private:
    sk_sp<SkFontMgr> fDelegate;
    std::vector<sk_sp<SkTypeface>> fFaces;
    std::vector<SkString> fFamilies;
};

struct kx_fonts {
    sk_sp<KxFontMgr> mgr = sk_make_sp<KxFontMgr>();
    sk_sp<skia::textlayout::FontCollection> collection;
};

skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts* f) {
    if (!f->collection) {
        f->collection = sk_make_sp<skia::textlayout::FontCollection>();
        f->collection->setAssetFontManager(f->mgr);
        f->collection->setDefaultFontManager(f->mgr);
        f->collection->enableFontFallback();
    }
    return f->collection.get();
}
const std::vector<SkString>* kx_fonts_families(kx_fonts* f) {
    return &f->mgr->families();
}

kx_fonts* kx_fonts_global(void) {
    static kx_fonts* g = new kx_fonts();
    return g;
}
int kx_fonts_add(kx_fonts* f, const void* data, size_t len) {
    if (!f || !data || !len) return -1;
    sk_sp<SkData> d = SkData::MakeWithCopy(data, len);
    int n = f->mgr->add(std::move(d));
    return n > 0 ? (int)f->mgr->families().size() - 1 : -1;
}
int kx_fonts_count(const kx_fonts* f) { return f ? f->mgr->faceCount() : 0; }
void kx_fonts_free(kx_fonts* f) {
    if (f && f != kx_fonts_global()) delete f;
}

// ---------------------------------------------------------------------------
// Contextes
// ---------------------------------------------------------------------------
struct kx_ctx {
    kx_backend backend = KX_BACKEND_RASTER;
    std::string driver;

    // Ganesh GL (WGL)
    HWND hwnd = nullptr;
    HDC hdc = nullptr;
    HGLRC glrc = nullptr;
    sk_sp<GrDirectContext> gr_ctx;
    sk_sp<const GrGLInterface> gl_iface;

    // Dawn / Graphite
    std::unique_ptr<dawn::native::Instance> dawn_instance;
    wgpu::Instance instance;
    wgpu::Device device;
    wgpu::Queue queue;
    wgpu::BackendType dawn_backend = wgpu::BackendType::Undefined;
    std::unique_ptr<graphite::Context> g_ctx;
    std::unique_ptr<graphite::Recorder> g_rec;

    // Cache image corpus (64x64 damier) par backend.
    sk_sp<SkImage> corpus_image;
    sk_sp<SkImage> corpus_raster;  // source raster pour TextureFromImage
};

static void kx_gl_destroy(kx_ctx* c) {
    if (c->glrc) { wglMakeCurrent(nullptr, nullptr); wglDeleteContext(c->glrc); }
    if (c->hdc && c->hwnd) ReleaseDC(c->hwnd, c->hdc);
    if (c->hwnd) DestroyWindow(c->hwnd);
    c->hwnd = nullptr; c->hdc = nullptr; c->glrc = nullptr;
}

// ---- Raster ----------------------------------------------------------------
kx_ctx* kx_ctx_create_raster(void) {
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_RASTER;
    c->driver = "raster-cpu";
    return c;
}

// ---- Ganesh GL via WGL ------------------------------------------------------
static ATOM kx_wndclass() {
    static ATOM a = [] {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"kx_gl_wnd";
        RegisterClassW(&wc);
        return wc.lpszClassName ? (ATOM)1 : (ATOM)0;
    }();
    return a;
}

kx_ctx* kx_ctx_create_ganesh_gl(void) {
    kx_wndclass();
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_GANESH_GL;

    c->hwnd = CreateWindowExW(0, L"kx_gl_wnd", L"kx", WS_POPUP,
                              0, 0, 16, 16, nullptr, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
    if (!c->hwnd) { delete c; return nullptr; }
    c->hdc = GetDC(c->hwnd);

    PIXELFORMATDESCRIPTOR pfd = {};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    int pf = ChoosePixelFormat(c->hdc, &pfd);
    if (!pf || !SetPixelFormat(c->hdc, pf, &pfd)) { kx_gl_destroy(c); delete c; return nullptr; }

    HGLRC boot = wglCreateContext(c->hdc);
    if (!boot || !wglMakeCurrent(c->hdc, boot)) { kx_gl_destroy(c); delete c; return nullptr; }

    // Contexte 4.5 core si dispo, sinon legacy (llvmpipe expose 4.5 en compat).
    auto wglCreateContextAttribsARB =
        (PFNWGLCREATECONTEXTATTRIBSARBPROC)wglGetProcAddress("wglCreateContextAttribsARB");
    HGLRC rc = nullptr;
    if (wglCreateContextAttribsARB) {
        const int attribs[] = {
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 5,
            WGL_CONTEXT_PROFILE_MASK_ARB, WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0
        };
        rc = wglCreateContextAttribsARB(c->hdc, nullptr, attribs);
    }
    if (rc) {
        wglMakeCurrent(nullptr, nullptr);
        wglDeleteContext(boot);
        wglMakeCurrent(c->hdc, rc);
        c->glrc = rc;
    } else {
        c->glrc = boot;  // legacy — OK pour llvmpipe (GL 4.5 compat)
    }

    c->gl_iface = GrGLInterfaces::MakeWin();
    if (!c->gl_iface) {
        c->driver = "ganesh-gl(wgl: no interface)";
        kx_gl_destroy(c); delete c; return nullptr;
    }
    c->gr_ctx = GrDirectContexts::MakeGL(c->gl_iface);
    if (!c->gr_ctx) {
        c->driver = "ganesh-gl(wgl: MakeGL failed)";
        kx_gl_destroy(c); delete c; return nullptr;
    }
    const char* renderer = (const char*)c->gl_iface->fFunctions.fGetString(GL_RENDERER);
    const char* version = (const char*)c->gl_iface->fFunctions.fGetString(GL_VERSION);
    c->driver = std::string("ganesh-gl(wgl:") + (renderer ? renderer : "?") +
                " " + (version ? version : "") + ")";
    return c;
}

// ---- Graphite Dawn (natif) --------------------------------------------------
static kx_ctx* kx_ctx_create_graphite_dawn_backend(wgpu::BackendType want) {
    static std::unique_ptr<dawn::native::Instance> sInst;
    static bool init = false;
    if (!init) {
        DawnProcTable procs = dawn::native::GetProcs();
        dawnProcSetProcs(&procs);
        wgpu::InstanceDescriptor desc{};
        static const wgpu::InstanceFeatureName timedWait =
            wgpu::InstanceFeatureName::TimedWaitAny;
        desc.requiredFeatureCount = 1;
        desc.requiredFeatures = &timedWait;
        sInst = std::make_unique<dawn::native::Instance>(&desc);
        init = true;
    }
    if (!sInst) return nullptr;

    wgpu::RequestAdapterOptions opts{};
    opts.featureLevel = wgpu::FeatureLevel::Core;
    std::vector<dawn::native::Adapter> adapters = sInst->EnumerateAdapters(&opts);
    dawn::native::Adapter picked;
    for (const auto& a : adapters) {
        wgpu::Adapter wa = a.Get();
        wgpu::AdapterInfo ai{};
        wa.GetInfo(&ai);
        if (ai.backendType == want) { picked = a; break; }
    }
    if (!picked) return nullptr;
    wgpu::AdapterInfo info{};
    wgpu::Adapter(picked.Get()).GetInfo(&info);

    wgpu::Adapter adapter = picked.Get();
    wgpu::DeviceDescriptor ddesc{};
    wgpu::Limits limits{};
    adapter.GetLimits(&limits);
    ddesc.requiredLimits = &limits;
    ddesc.SetUncapturedErrorCallback([](const wgpu::Device&, wgpu::ErrorType,
                                        wgpu::StringView msg) {
        fprintf(stderr, "[dawn error] %.*s\n", (int)msg.length, msg.data);
    });
    wgpu::Device device = adapter.CreateDevice(&ddesc);
    if (!device) return nullptr;

    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_GRAPHITE_DAWN;
    c->dawn_backend = want;
    c->instance = wgpu::Instance(sInst->Get());
    c->device = device;
    c->queue = device.GetQueue();

    const char* bt =
        want == wgpu::BackendType::D3D12 ? "d3d12" :
        want == wgpu::BackendType::Vulkan ? "vulkan" : "dawn";
    auto sv_str = [](wgpu::StringView sv) -> std::string {
        if (!sv.data) return {};
        if (sv.length == WGPU_STRLEN) return std::string(sv.data);
        return std::string(sv.data, sv.length);
    };
    std::string dev = sv_str(info.device);
    std::string dsc = sv_str(info.description);
    if (dev.empty()) dev = "?";
    const char* atype = info.adapterType == wgpu::AdapterType::CPU ? "cpu" : "gpu";
    c->driver = "graphite-dawn-" + std::string(bt) + "(" + dev +
                (dsc.empty() ? "" : "; " + dsc) + "; " + atype + ")";

    graphite::DawnBackendContext bc{};
    bc.fInstance = c->instance;
    bc.fDevice = c->device;
    bc.fQueue = c->queue;
    // fTick reste à DawnNativeProcessEventsFunction (défaut natif) → contexte
    // yielding → SyncToCpu::kYes autorisé → readback synchrone.

    graphite::ContextOptions options;
    graphite::ContextOptionsPriv priv;
    priv.fStoreContextRefInRecorder = true;  // requis readPixels sync
    options.fOptionsPriv = &priv;
    c->g_ctx = graphite::ContextFactory::MakeDawn(bc, options);
    if (!c->g_ctx) { delete c; return nullptr; }
    c->g_rec = c->g_ctx->makeRecorder();
    if (!c->g_rec) { delete c; return nullptr; }
    return c;
}

kx_ctx* kx_ctx_create_graphite_dawn_d3d12(void) {
    return kx_ctx_create_graphite_dawn_backend(wgpu::BackendType::D3D12);
}
kx_ctx* kx_ctx_create_graphite_dawn_vulkan(void) {
    return kx_ctx_create_graphite_dawn_backend(wgpu::BackendType::Vulkan);
}
// Backend Dawn par défaut = cible primaire Windows.
kx_ctx* kx_ctx_create_graphite_dawn(void) {
    return kx_ctx_create_graphite_dawn_d3d12();
}

// ---- Ganesh GL sur contexte courant (SDL/WGL déjà fait par le host) ----------
// Le host a déjà créé sa fenêtre + contexte GL et les a rendus courants ; le
// ctx ne possède ni hwnd ni glrc (rien à détruire de ce côté).
// GrGLGetProc a la signature (ctx, name) — kx_gl_getproc ABI prend (name)
// seul : adaptation par trampoline (get_proc passé en ctx).
static GrGLFuncPtr kx_gl_getproc_trampoline(void* ctx, const char name[]) {
    auto* gp = (kx_gl_getproc)ctx;
    return (GrGLFuncPtr)gp(name);
}
kx_ctx* kx_ctx_create_ganesh_gl_current(kx_gl_getproc get_proc) {
    if (!get_proc) return nullptr;
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_GANESH_GL;
    c->gl_iface = GrGLMakeAssembledInterface((void*)get_proc,
                                             kx_gl_getproc_trampoline);
    if (!c->gl_iface) {
        c->driver = "ganesh-gl(current: no interface)";
        delete c; return nullptr;
    }
    c->gr_ctx = GrDirectContexts::MakeGL(c->gl_iface);
    if (!c->gr_ctx) {
        c->driver = "ganesh-gl(current: MakeGL failed)";
        delete c; return nullptr;
    }
    const char* renderer = (const char*)c->gl_iface->fFunctions.fGetString(GL_RENDERER);
    const char* version = (const char*)c->gl_iface->fFunctions.fGetString(GL_VERSION);
    c->driver = std::string("ganesh-gl(current:") + (renderer ? renderer : "?") +
                " " + (version ? version : "") + ")";
    return c;
}

// Créateurs non-implémentés ici (wasm ou autres cibles) — stubs qui échouent
// proprement.
kx_ctx* kx_ctx_create_graphite_webgpu(void) { return nullptr; }
kx_ctx* kx_ctx_create_ganesh_webgl(const char*) { return nullptr; }
kx_ctx* kx_ctx_create_graphite_vulkan(void) { return nullptr; }
kx_ctx* kx_ctx_create_graphite_metal(void) { return nullptr; }
kx_target* kx_target_canvas(kx_ctx*, const char*, int, int) { return nullptr; }

kx_backend kx_ctx_backend(const kx_ctx* c) { return c ? c->backend : KX_BACKEND_RASTER; }
const char* kx_ctx_driver_info(const kx_ctx* c) { return c ? c->driver.c_str() : "null"; }

int kx_ctx_has_unfinished_work(kx_ctx* c) {
    return c && c->g_ctx ? (c->g_ctx->hasUnfinishedGpuWork() ? 1 : 0) : 0;
}

void kx_ctx_free(kx_ctx* c) {
    if (!c) return;
    if (c->g_ctx) {
        // Drain avant destruction (contexte yielding → on peut attendre).
        if (c->g_ctx->hasUnfinishedGpuWork())
            c->g_ctx->submit(graphite::SyncToCpu::kYes);
        c->g_rec.reset();
        c->g_ctx.reset();
        if (c->instance) c->instance.ProcessEvents();
        c->device = nullptr;
    }
    kx_gl_destroy(c);
    delete c;
}

// ---------------------------------------------------------------------------
// Cibles
// ---------------------------------------------------------------------------
kx_target* kx_target_offscreen(kx_ctx* c, int w, int h) {
    if (!c || w <= 0 || h <= 0) return nullptr;
    auto* t = new kx_target();
    t->ctx = c; t->w = w; t->h = h;
    SkImageInfo info = SkImageInfo::MakeN32Premul(w, h);
    switch (c->backend) {
        case KX_BACKEND_RASTER:
            t->surface = SkSurfaces::Raster(info);
            break;
        case KX_BACKEND_GANESH_GL:
            t->surface = SkSurfaces::RenderTarget(c->gr_ctx.get(), Budgeted::kYes,
                                                  info, 0, kTopLeft_GrSurfaceOrigin,
                                                  nullptr);
            break;
        case KX_BACKEND_GRAPHITE_DAWN:
            t->surface = SkSurfaces::RenderTarget(c->g_rec.get(), info,
                                                  Mipmapped::kNo, nullptr);
            break;
        default: break;
    }
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

// ---- Cibles onscreen --------------------------------------------------------
// Swapchain Dawn pour HWND (K1 Windows) : surface WebGPU configurée BGRA8,
// backbuffer réacquis à chaque frame (GetCurrentTexture + WrapBackendTexture).
struct kx_dawn_surface {
    wgpu::Surface surface;
};

kx_target* kx_target_onscreen_gl(kx_ctx* c, int w, int h) {
    if (!c || c->backend != KX_BACKEND_GANESH_GL || !c->gr_ctx || w <= 0 || h <= 0)
        return nullptr;
    GrGLFramebufferInfo fbi{};
    fbi.fFBOID = 0;                       // framebuffer par défaut = la fenêtre
    fbi.fFormat = 0x8058;                 // GL_RGBA8
    auto brt = GrBackendRenderTargets::MakeGL(w, h, 0, 8, fbi);
    if (!brt.isValid()) return nullptr;
    auto* t = new kx_target();
    t->ctx = c; t->w = w; t->h = h; t->onscreen = true;
    t->surface = SkSurfaces::WrapBackendRenderTarget(
        c->gr_ctx.get(), brt, kBottomLeft_GrSurfaceOrigin,
        kRGBA_8888_SkColorType, nullptr, nullptr);
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

kx_target* kx_target_onscreen_dawn(kx_ctx* c, void* hwnd, int w, int h) {
    if (!c || c->backend != KX_BACKEND_GRAPHITE_DAWN || !c->instance ||
        !hwnd || w <= 0 || h <= 0)
        return nullptr;

    wgpu::SurfaceSourceWindowsHWND src{};
    src.hinstance = (void*)GetModuleHandleW(nullptr);
    src.hwnd = hwnd;
    wgpu::SurfaceDescriptor sdesc{};
    sdesc.nextInChain = &src;
    wgpu::Surface surf = c->instance.CreateSurface(&sdesc);
    if (!surf) return nullptr;

    wgpu::SurfaceConfiguration cfg{};
    cfg.device = c->device;
    cfg.format = wgpu::TextureFormat::BGRA8Unorm;   // swapchain Windows standard
    cfg.usage = wgpu::TextureUsage::RenderAttachment;
    cfg.width = (uint32_t)w;
    cfg.height = (uint32_t)h;
    cfg.presentMode = wgpu::PresentMode::Fifo;      // vsync (throttle naturel)
    cfg.alphaMode = wgpu::CompositeAlphaMode::Auto;
    surf.Configure(&cfg);

    auto* t = new kx_target();
    t->ctx = c; t->w = w; t->h = h; t->onscreen = true;
    auto* ds = new kx_dawn_surface();
    ds->surface = surf;
    t->dawn = ds;
    // t->surface reste nul : la swapchain est acquise au moment du draw.
    return t;
}

void kx_target_free(kx_target* t) {
    if (!t) return;
    delete t->dawn;
    delete t;
}
void kx_target_size(const kx_target* t, int* w, int* h) {
    if (w) *w = t ? t->w : 0;
    if (h) *h = t ? t->h : 0;
}

// ---------------------------------------------------------------------------
// Flush / submit
// ---------------------------------------------------------------------------
int kx_flush_target(kx_ctx* c, kx_target* t) {
    if (!c) c = t ? t->ctx : nullptr;
    if (!t || !t->surface || !t->dirty || !c) return 0;
    switch (c->backend) {
        case KX_BACKEND_GANESH_GL:
            c->gr_ctx->flushAndSubmit(t->surface.get());
            break;
        case KX_BACKEND_GRAPHITE_DAWN: {
            auto recording = c->g_rec->snap();
            if (!recording) return -1;
            graphite::InsertRecordingInfo ri{};
            ri.fRecording = recording.get();
            if (c->g_ctx->insertRecording(ri) != graphite::InsertStatus::kSuccess)
                return -2;
            c->g_ctx->submit(graphite::SyncToCpu::kYes);
            break;
        }
        default: break;  // raster : rien à faire
    }
    t->dirty = false;
    return 0;
}

// Acquisition du backbuffer swapchain pour une cible onscreen Dawn.
// Réutilise le schéma wasm/GraphiteDawnWindowContext : GetCurrentTexture →
// BackendTextures::MakeDawn → SkSurfaces::WrapBackendTexture.
int kx_graphite_canvas_acquire(kx_target* t) {
    if (!t || !t->ctx) return -1;
    if (!t->dawn || !t->dawn->surface) return -2;
    wgpu::SurfaceTexture st{};
    t->dawn->surface.GetCurrentTexture(&st);
    if (!st.texture ||
        (st.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessOptimal &&
         st.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal))
        return -3;
    graphite::DawnTextureInfo info(graphite::SampleCount::k1, Mipmapped::kNo,
                                   wgpu::TextureFormat::BGRA8Unorm,
                                   st.texture.GetUsage(),
                                   wgpu::TextureAspect::All);
    auto bt = graphite::BackendTextures::MakeDawn(st.texture.Get());
    t->surface = SkSurfaces::WrapBackendTexture(t->ctx->g_rec.get(), bt,
                                              nullptr, nullptr);
    if (!t->surface) return -4;
    return 0;
}

SkCanvas* kx_target_canvas_ready(kx_target* t) {
    if (!t) return nullptr;
    if (!t->surface) {
        if (kx_graphite_canvas_acquire(t)) return nullptr;
    }
    return t->surface->getCanvas();
}

// Acquisition paresseuse canonique : onscreen sans surface → reacquire
// (dawn : backbuffer swapchain par frame). Autres backends : no-op.
int kx_acquire_surface(kx_target* t) {
    if (!t) return -1;
    if (t->dawn) return kx_graphite_canvas_acquire(t);
    return 0;
}

int kx_present(kx_ctx* c, kx_target* t) {
    if (!c || !t) return -1;
    if (kx_flush_target(c, t)) return -2;
    if (t->dawn && t->dawn->surface) {
        t->dawn->surface.Present();
        t->surface.reset();   // backbuffer rendu : invalide après Present
        return 0;
    }
    return 0;   // GL onscreen : swap géré par le host (SDL_GL_SwapWindow)
}

// ---------------------------------------------------------------------------
// Image corpus (damier 64×64, déterministe) — texture native pour GPU.
// ---------------------------------------------------------------------------
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx* c) {
    if (!c) return nullptr;
    if (c->corpus_image) return c->corpus_image;

    if (!c->corpus_raster) {
        const int S = 64;
        SkBitmap bmp;
        bmp.allocPixels(SkImageInfo::MakeN32Premul(S, S));
        bmp.eraseColor(SK_ColorWHITE);
        uint32_t* px = (uint32_t*)bmp.getPixels();
        for (int y = 0; y < S; ++y)
            for (int x = 0; x < S; ++x) {
                int ch = ((x / 8) + (y / 8)) & 1;
                SkColor col = ch ? 0xFF3A7BD5 : 0xFFE11D48;
                if (((x * 31 + y * 17) & 0x7F) < 6) col = 0xFF10B981;  // points verts
                px[y * S + x] = col;
            }
        bmp.setImmutable();
        c->corpus_raster = bmp.asImage();
    }
    switch (c->backend) {
        case KX_BACKEND_RASTER:
            c->corpus_image = c->corpus_raster;
            break;
        case KX_BACKEND_GANESH_GL:
            c->corpus_image = SkImages::TextureFromImage(c->gr_ctx.get(),
                                                       c->corpus_raster);
            break;
        case KX_BACKEND_GRAPHITE_DAWN:
            c->corpus_image = SkImages::TextureFromImage(c->g_rec.get(),
                                                       c->corpus_raster, {});
            break;
        default: break;
    }
    return c->corpus_image;
}

// ---------------------------------------------------------------------------
// Readback (natif : synchrone autorisé)
// ---------------------------------------------------------------------------
struct kx_readback {
    std::vector<uint8_t> pixels;
    int w = 0, h = 0;
    int status = 0;  // 0 en attente, 1 prêt, <0 échec
};

kx_readback* kx_readback_start(kx_ctx* c, kx_target* t) {
    if (!c || !t || !t->surface) return nullptr;
    auto* rb = new kx_readback();
    rb->w = t->w; rb->h = t->h;
    rb->pixels.resize((size_t)t->w * t->h * 4);

    if (kx_flush_target(c, t)) { rb->status = -2; return rb; }

    SkImageInfo dst = SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                        kPremul_SkAlphaType);
    switch (c->backend) {
        case KX_BACKEND_GRAPHITE_DAWN: {
            auto* rb2 = rb;
            c->g_ctx->asyncRescaleAndReadPixels(
                t->surface.get(), dst, SkIRect::MakeWH(t->w, t->h),
                SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                [](void* ctx, std::unique_ptr<const SkImage::AsyncReadResult> res) {
                    auto* rb = (kx_readback*)ctx;
                    if (!res || res->count() < 1 || !res->data(0)) {
                        rb->status = -3; return;
                    }
                    size_t src_rb = res->rowBytes(0);
                    const uint8_t* src = (const uint8_t*)res->data(0);
                    if (src_rb == (size_t)rb->w * 4) {
                        memcpy(rb->pixels.data(), src, rb->pixels.size());
                    } else {
                        for (int y = 0; y < rb->h; ++y)
                            memcpy(rb->pixels.data() + (size_t)y * rb->w * 4,
                                   src + (size_t)y * src_rb, (size_t)rb->w * 4);
                    }
                    rb->status = 1;
                },
                rb2);
            // submit(SyncToCpu::kYes) + tick déclenche le callback à complétion.
            c->g_ctx->submit(graphite::SyncToCpu::kYes);
            c->instance.ProcessEvents();
            c->g_ctx->checkAsyncWorkCompletion();
            if (rb->status == 0) rb->status = -4;  // callback non appelé
            break;
        }
        case KX_BACKEND_GANESH_GL: {
            SkPixmap pm(dst, rb->pixels.data(), (size_t)t->w * 4);
            rb->status = t->surface->readPixels(pm, 0, 0) ? 1 : -3;
            break;
        }
        default: {  // raster
            SkPixmap pm(dst, rb->pixels.data(), (size_t)t->w * 4);
            rb->status = t->surface->readPixels(pm, 0, 0) ? 1 : -3;
            break;
        }
    }
    return rb;
}

int kx_readback_poll(kx_ctx*, kx_readback* rb) {
    return rb ? rb->status : -1;
}

int kx_readback_copy(const kx_readback* rb, uint8_t* dst) {
    if (!rb || rb->status != 1) return -1;
    memcpy(dst, rb->pixels.data(), rb->pixels.size());
    return (int)rb->pixels.size();
}

int64_t kx_readback_copy_n(const kx_readback* rb, void* dst, size_t len) {
    if (!rb || rb->status != 1 || !dst) return -1;
    if (len < rb->pixels.size()) return -2;
    memcpy(dst, rb->pixels.data(), rb->pixels.size());
    return (int64_t)rb->pixels.size();
}

void kx_readback_free(kx_readback* rb) { delete rb; }

// ---------------------------------------------------------------------------
// Helper PNG pour le runner (hors ABI kx_skia) : encode un buffer RGBA8888
// premultiplied via SkPngEncoder (libpng).
// ---------------------------------------------------------------------------
extern "C" int kx_png_write(const char* path, const uint8_t* rgba, int w, int h) {
    if (!path || !rgba || w <= 0 || h <= 0) return -1;
    SkImageInfo info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType,
                                       kPremul_SkAlphaType);
    SkPixmap pm(info, rgba, (size_t)w * 4);
    SkFILEWStream out(path);
    if (!out.isValid()) return -2;
    SkPngEncoder::Options opts;
    return SkPngEncoder::Encode(&out, pm, opts) ? 0 : -3;
}

// Accesseurs backend pour kx_draw.cpp (kx_ctx opaque hors de ce fichier) —
// noms canoniques partagés avec la variante linux/wasm.
GrDirectContext* kx_ctx_gr_context(kx_ctx* c) { return c ? c->gr_ctx.get() : nullptr; }
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx* c) { return c ? c->g_rec.get() : nullptr; }

// Metal : plateforme non concernée (macOS/iOS seulement).
kx_target* kx_target_onscreen_metal(kx_ctx*, void*, int, int, double) { return nullptr; }

// ---------------------------------------------------------------------------
// Bench : médiane des itérations draw+submit+readback (chemin complet).
// ---------------------------------------------------------------------------
double kx_bench_ms(kx_ctx* c, kx_fonts* f, kx_target* t, int scene, int iters) {
    if (!c || !t) return -1;
    std::vector<double> times;
    times.reserve(iters);
    for (int i = 0; i < iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        double phase = (double)(i % 60) / 60.0;
        if (kx_scene_draw(c, f, t, scene, phase)) return -2;
        // Flush + readback complet = present/finalize offscreen.
        kx_readback* rb = kx_readback_start(c, t);
        if (!rb || rb->status != 1) { kx_readback_free(rb); return -3; }
        auto t1 = std::chrono::steady_clock::now();
        kx_readback_free(rb);
        times.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
    }
    std::sort(times.begin(), times.end());
    return times[times.size() / 2];
}

// ---------------------------------------------------------------------------
// Stubs métal (déclarés dans kx_internal.h canonique, implémentés sur macOS).
// ---------------------------------------------------------------------------
int kx_metal_acquire(kx_target*) { return -1; }
int kx_metal_present(kx_target*) { return -1; }

// ---------------------------------------------------------------------------
// Fontes : index famille + scan de répertoire (miroir kx_skia_linux.cpp).
// ---------------------------------------------------------------------------
int kx_fonts_family_index(const kx_fonts* cf, const char* name) {
    if (!cf || !name) return -1;
    const auto* fams = &const_cast<kx_fonts*>(cf)->mgr->families();
    for (size_t i = 0; i < fams->size(); ++i)
        if ((*fams)[i].equals(name)) return (int)i;
    return -1;
}

// Scan récursif .ttf/.otf/.ttc — Win32 (miroir du readdir linux : tri +
// profondeur plafonnée, échecs de parse ignorés).
static int fonts_add_dir_rec(kx_fonts* f, const std::string& dir, int depth) {
    if (depth > 6) return 0;
    std::vector<std::string> files, subs;
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA((dir + "\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    do {
        if (fd.cFileName[0] == '.') continue;
        std::string path = dir + "\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            subs.push_back(path);
            continue;
        }
        size_t n = strlen(fd.cFileName);
        if (n < 4) continue;
        std::string ext = fd.cFileName + n - 4;
        for (auto& c : ext) c = (char)tolower((unsigned char)c);
        if (ext == ".ttf" || ext == ".otf" || ext == ".ttc")
            files.push_back(path);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
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
