// kx_skia_linux.cpp — implémentation native Linux de l'ABI kx_skia.
// Backends : raster (toujours), Ganesh GL via EGL surfaceless, Graphite Vulkan.
// Mêmes fonctions/scènes que W0 ; readback synchrone possible en natif.
#include "kx_skia.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkStream.h"
#include "include/core/SkString.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanMemoryAllocator.h"
#include "include/gpu/vk/VulkanPreferredFeatures.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include <GL/gl.h>
#include "src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorPriv.h"
#include "src/gpu/GpuTypesPriv.h"
#include "src/ports/SkFontMgr_custom.h"
#include "src/ports/SkTypeface_FreeType.h"
#include "include/ports/SkFontMgr_empty.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

using skgpu::Mipmapped;
using skgpu::Renderable;
using skgpu::graphite::BackendTexture;
using skgpu::graphite::Context;
using skgpu::graphite::ContextOptions;
using skgpu::graphite::Recorder;

// ---------------------------------------------------------------------------
// Fontes — même KxFontMgr que W0 (référence : SkFontMgr_New_Custom_Empty
// n'indexe pas les faces chargées).
// ---------------------------------------------------------------------------
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
            if (s->getFamilyName().equals(name)) { s->appendTypeface(std::move(tf)); return; }
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
        for (auto& s : fSets) if (s->getFamilyName().equals(name)) return s;
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
    for (int i = 0; i < 16; ++i) {
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
void kx_fonts_free(kx_fonts* f) { delete f; }

int kx_fonts_family_index(const kx_fonts* f, const char* name) {
    if (!f || !name) return -1;
    for (size_t i = 0; i < f->families.size(); ++i)
        if (f->families[i].equals(name)) return (int)i;
    return -1;
}

// Scan récursif .ttf/.otf/.ttc — POSIX. Les échecs de parse sont ignorés
// (fichier corrompu ≠ fatal). Ordre = readdir (déterminisme assuré par
// tri avant chargement).
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

// ---------------------------------------------------------------------------
// Contextes
// ---------------------------------------------------------------------------
struct kx_ctx {
    kx_backend backend;
    std::string driver;

    // raster
    sk_sp<SkSurface> raster_surface_proto;

    // ganesh GL
    sk_sp<GrDirectContext> gr;
    EGLDisplay egl_display = EGL_NO_DISPLAY;
    EGLContext egl_context = EGL_NO_CONTEXT;
    std::string gl_renderer;

    // graphite vulkan
    VkPhysicalDeviceFeatures2 vk_feats2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
    VkInstance vk_instance = VK_NULL_HANDLE;
    VkPhysicalDevice vk_phys = VK_NULL_HANDLE;
    VkDevice vk_device = VK_NULL_HANDLE;
    VkQueue vk_queue = VK_NULL_HANDLE;
    uint32_t vk_qindex = 0;
    skgpu::VulkanExtensions vk_ext;
    skgpu::VulkanBackendContext vk_bc;
    std::unique_ptr<Context> gctx;
    std::unique_ptr<Recorder> recorder;

    sk_sp<SkImage> corpus_img;
};

const char* kx_ctx_driver_info(const kx_ctx* c) { return c ? c->driver.c_str() : "none"; }
kx_backend kx_ctx_backend(const kx_ctx* c) { return c->backend; }
int kx_ctx_has_unfinished_work(kx_ctx*) { return 0; }  // natif : submits synchrones

// --- Raster -----------------------------------------------------------------
kx_ctx* kx_ctx_create_raster(void) {
    auto c = new kx_ctx();
    c->backend = KX_BACKEND_RASTER;
    c->driver = "raster-cpu";
    return c;
}

// --- Ganesh GL (EGL surfaceless) ---------------------------------------------
kx_ctx* kx_ctx_create_ganesh_gl(void) {
    auto c = new kx_ctx();
    c->backend = KX_BACKEND_GANESH_GL;

    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA,
                                         EGL_DEFAULT_DISPLAY, nullptr);
    if (dpy == EGL_NO_DISPLAY) dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, nullptr, nullptr)) {
        delete c; return nullptr;
    }
    eglBindAPI(EGL_OPENGL_API);
    EGLint cfg_attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                           EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
                           EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                           EGL_NONE };
    EGLConfig cfg; EGLint ncfg = 0;
    if (!eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &ncfg) || ncfg < 1) {
        delete c; return nullptr;
    }
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT,
        (EGLint[]){ EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE });
    // client_version=2 + OPENGL_API = compat desktop GL sur mesa
    if (ctx == EGL_NO_CONTEXT) {
        ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, nullptr);
        if (ctx == EGL_NO_CONTEXT) { delete c; return nullptr; }
    }
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg,
        (EGLint[]){ EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE });
    if (surf == EGL_NO_SURFACE || !eglMakeCurrent(dpy, surf, surf, ctx)) {
        delete c; return nullptr;
    }

    auto iface = GrGLMakeAssembledInterface(
            nullptr,
            [](void*, const char* name) -> GrGLFuncPtr {
                return (GrGLFuncPtr) eglGetProcAddress(name);
            });
    if (!iface || !iface->validate()) { delete c; return nullptr; }
    c->gr = GrDirectContexts::MakeGL(std::move(iface));
    if (!c->gr) { delete c; return nullptr; }

    const char* rend = (const char*)glGetString(GL_RENDERER);
    const char* vend = (const char*)glGetString(GL_VENDOR);
    c->driver = std::string("ganesh-gl(") + (rend ? rend : "?") + ";" +
                (vend ? vend : "?") + ")";
    c->egl_display = dpy;
    c->egl_context = ctx;
    return c;
}

// --- Graphite Vulkan ----------------------------------------------------------
static void vk_die() {}

kx_ctx* kx_ctx_create_graphite_vulkan(void) {
    auto c = new kx_ctx();
    c->backend = KX_BACKEND_GRAPHITE_VULKAN;

    skgpu::VulkanPreferredFeatures preferred;
    preferred.init(VK_API_VERSION_1_1);

    // instance
    uint32_t ic = 0;
    vkEnumerateInstanceExtensionProperties(nullptr, &ic, nullptr);
    std::vector<VkExtensionProperties> iprops(ic);
    vkEnumerateInstanceExtensionProperties(nullptr, &ic, iprops.data());
    std::vector<const char*> inst_exts;
    preferred.addToInstanceExtensions(iprops.data(), ic, inst_exts);
    // headless : aucune extension surface requise

    VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    ai.pApplicationName = "kx";
    ai.applicationVersion = 1;
    ai.pEngineName = "kx";
    ai.engineVersion = 1;
    ai.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &ai;
    ici.enabledExtensionCount = (uint32_t)inst_exts.size();
    ici.ppEnabledExtensionNames = inst_exts.data();
    if (vkCreateInstance(&ici, nullptr, &c->vk_instance) != VK_SUCCESS) {
        delete c; return nullptr;
    }
    auto vkGetProc = [](const char* name, VkInstance inst, VkDevice dev) {
        if (dev != VK_NULL_HANDLE) {
            auto p = vkGetDeviceProcAddr(dev, name);
            if (p) return (PFN_vkVoidFunction)p;
        }
        return (PFN_vkVoidFunction)vkGetInstanceProcAddr(inst, name);
    };

    uint32_t pc = 0;
    vkEnumeratePhysicalDevices(c->vk_instance, &pc, nullptr);
    if (pc == 0) { delete c; return nullptr; }
    std::vector<VkPhysicalDevice> devs(pc);
    vkEnumeratePhysicalDevices(c->vk_instance, &pc, devs.data());
    c->vk_phys = devs[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(c->vk_phys, &props);
    c->driver = std::string("graphite-vulkan(") + props.deviceName + ")";

    // queue famille graphique
    uint32_t qc = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(c->vk_phys, &qc, nullptr);
    std::vector<VkQueueFamilyProperties> qprops(qc);
    vkGetPhysicalDeviceQueueFamilyProperties(c->vk_phys, &qc, qprops.data());
    uint32_t gi = UINT32_MAX;
    for (uint32_t i = 0; i < qc; ++i)
        if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { gi = i; break; }
    if (gi == UINT32_MAX) { delete c; return nullptr; }
    c->vk_qindex = gi;

    // device + features requises par Skia
    auto& feats2 = c->vk_feats2;  // vit dans kx_ctx : vk_bc y réfère
    vkGetPhysicalDeviceFeatures2(c->vk_phys, &feats2);
    std::vector<const char*> dev_exts;
    uint32_t dc = 0;
    vkEnumerateDeviceExtensionProperties(c->vk_phys, nullptr, &dc, nullptr);
    std::vector<VkExtensionProperties> dprops(dc);
    vkEnumerateDeviceExtensionProperties(c->vk_phys, nullptr, &dc, dprops.data());
    preferred.addFeaturesToQuery(dprops.data(), dc, feats2);
    preferred.addFeaturesToEnable(dev_exts, feats2);

    float prio = 0.f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = gi;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.pQueueCreateInfos = &qci;
    dci.queueCreateInfoCount = 1;
    dci.enabledExtensionCount = (uint32_t)dev_exts.size();
    dci.ppEnabledExtensionNames = dev_exts.data();
    dci.pNext = &feats2;
    if (vkCreateDevice(c->vk_phys, &dci, nullptr, &c->vk_device) != VK_SUCCESS) {
        delete c; return nullptr;
    }
    vkGetDeviceQueue(c->vk_device, gi, 0, &c->vk_queue);

    c->vk_ext.init(vkGetProc, c->vk_instance, c->vk_phys,
                   (uint32_t)inst_exts.size(), inst_exts.data(),
                   (uint32_t)dev_exts.size(), dev_exts.data());

    c->vk_bc.fInstance = c->vk_instance;
    c->vk_bc.fPhysicalDevice = c->vk_phys;
    c->vk_bc.fDevice = c->vk_device;
    c->vk_bc.fQueue = c->vk_queue;
    c->vk_bc.fGraphicsQueueIndex = gi;
    c->vk_bc.fMaxAPIVersion = VK_API_VERSION_1_1;
    c->vk_bc.fVkExtensions = &c->vk_ext;
    c->vk_bc.fDeviceFeatures2 = &feats2;
    c->vk_bc.fGetProc = vkGetProc;
    // VMA requis par Graphite natif
    c->vk_bc.fMemoryAllocator = skgpu::VulkanMemoryAllocators::Make(
            c->vk_bc, skgpu::ThreadSafe::kYes);
    if (!c->vk_bc.fMemoryAllocator) { delete c; return nullptr; }

    c->gctx = skgpu::graphite::ContextFactory::MakeVulkan(c->vk_bc,
                                                        ContextOptions{});
    if (!c->gctx) { delete c; return nullptr; }
    c->recorder = c->gctx->makeRecorder();
    return c;
}

void kx_ctx_free(kx_ctx* c) {
    if (!c) return;
    if (c->gctx) {
        c->recorder.reset();
        c->gctx->submit(skgpu::graphite::SyncToCpu::kYes);
        c->gctx.reset();
    }
    if (c->vk_device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(c->vk_device);
        vkDestroyDevice(c->vk_device, nullptr);
        vkDestroyInstance(c->vk_instance, nullptr);
    }
    if (c->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(c->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(c->egl_display, c->egl_context);
        eglTerminate(c->egl_display);
    }
    delete c;
}

// ---------------------------------------------------------------------------
// Cibles
// ---------------------------------------------------------------------------
struct kx_target {
    kx_ctx* ctx;
    sk_sp<SkSurface> surface;
    int w, h;
    bool onscreen = false;
};

static SkSurface* make_surface(kx_ctx* c, int w, int h) {
    SkImageInfo ii = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType,
                                       kPremul_SkAlphaType,
                                       SkColorSpace::MakeSRGB());
    switch (c->backend) {
        case KX_BACKEND_RASTER:
            return SkSurfaces::Raster(ii).release();
        case KX_BACKEND_GANESH_GL:
            return SkSurfaces::RenderTarget(c->gr.get(), skgpu::Budgeted::kYes,
                                            ii, 0, kTopLeft_GrSurfaceOrigin,
                                            nullptr, false).release();
        case KX_BACKEND_GRAPHITE_VULKAN:
            return SkSurfaces::RenderTarget(c->recorder.get(), ii,
                                            skgpu::Mipmapped::kNo, nullptr).release();
        default: return nullptr;
    }
}

kx_target* kx_target_offscreen(kx_ctx* c, int w, int h) {
    if (!c || w <= 0 || h <= 0) return nullptr;
    auto t = new kx_target();
    t->ctx = c; t->w = w; t->h = h;
    t->surface = sk_sp<SkSurface>(make_surface(c, w, h));
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

void kx_target_size(const kx_target* t, int* w, int* h) {
    if (w) *w = t->w; if (h) *h = t->h;
}
void kx_target_free(kx_target* t) { delete t; }

// image corpus en texture GPU quand le backend l'exige
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx* c) {
    if (c->corpus_img) return c->corpus_img;
    const int n = 64;
    SkImageInfo ii = SkImageInfo::Make(n, n, kRGBA_8888_SkColorType,
                                     kPremul_SkAlphaType,
                                     SkColorSpace::MakeSRGB());
    std::vector<uint32_t> px((size_t)n * n);
    for (int y = 0; y < n; ++y)
        for (int x = 0; x < n; ++x)
            px[y * n + x] = (((x / 8) + (y / 8)) & 1)
                    ? SkColorSetARGB(255, 40 + x * 3, 160, 255 - y * 3)
                    : SkColorSetARGB(255, 200, 60 + y * 2, 90);
    auto raster = SkImages::RasterFromData(
            ii, SkData::MakeWithCopy(px.data(), px.size() * 4), n * 4);
    if (c->backend == KX_BACKEND_GRAPHITE_VULKAN)
        c->corpus_img = SkImages::TextureFromImage(c->recorder.get(), raster.get(), {});
    else
        c->corpus_img = std::move(raster);
    return c->corpus_img;
}

// ---------------------------------------------------------------------------
// Flush / présentation / readback
// ---------------------------------------------------------------------------
int kx_flush_target(kx_ctx* c, kx_target* t) {
    if (!c || !t || !t->surface) return -1;
    switch (c->backend) {
        case KX_BACKEND_GRAPHITE_VULKAN: {
            std::unique_ptr<skgpu::graphite::Recording> rec = c->recorder->snap();
            if (rec) {
                skgpu::graphite::InsertRecordingInfo info;
                info.fRecording = rec.get();
                if (!c->gctx->insertRecording(info)) return -2;
            }
            c->gctx->submit(skgpu::graphite::SyncToCpu::kYes);
            return 0;
        }
        case KX_BACKEND_GANESH_GL:
            c->gr->flushAndSubmit();
            return 0;
        default:
            return 0;  // raster : rien à pousser
    }
}

int kx_present(kx_ctx* c, kx_target* t) { return kx_flush_target(c, t); }

int kx_graphite_canvas_acquire(kx_target*) { return -1; }  // no aplica en nativo
int kx_acquire_surface(kx_target*) { return 0; }              // surfaces déjà posées (gl/dawn/raster)
int kx_metal_acquire(kx_target*) { return -1; }              // impl dans kx_skia_macos.cpp
int kx_metal_present(kx_target*) { return -1; }

struct kx_readback {
    std::vector<uint8_t> px;
    int w = 0, h = 0;
    bool ready = false;
};

kx_readback* kx_readback_start(kx_ctx* c, kx_target* t) {
    if (!c || !t || !t->surface) return nullptr;
    auto rb = new kx_readback();
    rb->w = t->w; rb->h = t->h;
    rb->px.resize((size_t)t->w * t->h * 4);

    if (c->backend == KX_BACKEND_GRAPHITE_VULKAN) {
        // synchronise le recorder + travail en cours
        kx_flush_target(c, t);
        SkImageInfo dst = SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                          kPremul_SkAlphaType,
                                          SkColorSpace::MakeSRGB());
        struct Cb { kx_readback* rb; bool* done; };
        bool done = false;
        Cb cb{rb, &done};
        c->gctx->asyncRescaleAndReadPixels(
                t->surface.get(), dst,
                SkIRect::MakeWH(t->w, t->h),
                SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                [](void* ctx_, std::unique_ptr<const SkImage::AsyncReadResult> r) {
                    auto* cb = (Cb*)ctx_;
                    if (r && r->count() >= 1) {
                        auto d0 = r->data(0);
                        memcpy(cb->rb->px.data(), d0,
                               std::min(cb->rb->px.size(), r->rowBytes(0) * cb->rb->h));
                    }
                    *cb->done = true;
                }, &cb);
        c->gctx->submit(skgpu::graphite::SyncToCpu::kYes);
        if (!done) { delete rb; return nullptr; }
        rb->ready = true;
        return rb;
    }

    // ganesh / raster : readPixels synchrone
    SkImageInfo dst = SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                       kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    if (!t->surface->readPixels(dst, rb->px.data(), t->w * 4, 0, 0)) {
        delete rb; return nullptr;
    }
    rb->ready = true;
    return rb;
}

int kx_readback_poll(kx_ctx*, kx_readback* rb) {
    return rb && rb->ready ? 1 : (rb ? 0 : -1);
}

int kx_readback_copy(const kx_readback* rb, uint8_t* dst) {
    if (!rb || !rb->ready || !dst) return -1;
    memcpy(dst, rb->px.data(), rb->px.size());
    return (int)rb->px.size();
}

int64_t kx_readback_copy_n(const kx_readback* rb, void* dst, size_t len) {
    if (!rb || !rb->ready || len < rb->px.size()) return -1;
    memcpy(dst, rb->px.data(), rb->px.size());
    return (int64_t)rb->px.size();
}

// Backends no implementados en esta plataforma (stubs honestos).
kx_ctx* kx_ctx_create_ganesh_webgl(const char*) { return nullptr; }
kx_ctx* kx_ctx_create_graphite_webgpu(void) { return nullptr; }
kx_ctx* kx_ctx_create_graphite_metal(void) { return nullptr; }
kx_ctx* kx_ctx_create_graphite_dawn(void) { return nullptr; }
kx_ctx* kx_ctx_create(void);  /* no existe: previene uso genérico */
kx_target* kx_target_canvas(kx_ctx*, const char*, int, int) { return nullptr; }

void kx_readback_free(kx_readback* rb) { delete rb; }

// ---------------------------------------------------------------------------
// Bench : draw + flush/submit complet, médiane des iters
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// K1 : contexte GL courant (SDL) + cible fb0 onscreen
// ---------------------------------------------------------------------------
kx_ctx* kx_ctx_create_ganesh_gl_current(kx_gl_getproc get_proc) {
    if (!get_proc) return nullptr;
    auto c = new kx_ctx();
    c->backend = KX_BACKEND_GANESH_GL;
    auto iface = GrGLMakeAssembledInterface(
            (void*)get_proc,
            [](void* ctx, const char* name) -> GrGLFuncPtr {
                return (GrGLFuncPtr) ((kx_gl_getproc)ctx)(name);
            });
    if (!iface || !iface->validate()) { delete c; return nullptr; }
    c->gr = GrDirectContexts::MakeGL(std::move(iface));
    if (!c->gr) { delete c; return nullptr; }
    const char* rend = (const char*)glGetString(GL_RENDERER);
    const char* vend = (const char*)glGetString(GL_VENDOR);
    c->driver = std::string("ganesh-gl-current(") + (rend ? rend : "?") + ";" +
                (vend ? vend : "?") + ")";
    return c;
}

kx_target* kx_target_onscreen_gl(kx_ctx* c, int w, int h) {
    if (!c || c->backend != KX_BACKEND_GANESH_GL || w <= 0 || h <= 0)
        return nullptr;
    auto t = new kx_target();
    t->ctx = c; t->w = w; t->h = h; t->onscreen = true;
    GrGLFramebufferInfo fb;
    fb.fFBOID = 0;
    fb.fFormat = 0x8058;  // GL_RGBA8
    GrBackendRenderTarget rt = GrBackendRenderTargets::MakeGL(w, h, 0, 8, fb);
    t->surface = SkSurfaces::WrapBackendRenderTarget(
            c->gr.get(), rt, kBottomLeft_GrSurfaceOrigin,
            kRGBA_8888_SkColorType, nullptr, nullptr);
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

extern "C" int kx_scene_draw(kx_ctx*, kx_fonts*, kx_target*, int, double);

double kx_bench_ms(kx_ctx* c, kx_fonts* f, kx_target* t, int scene, int iters) {
    if (!c || !t) return -1.0;
    std::vector<double> ts;
    ts.reserve(iters);
    for (int i = 0; i < iters; ++i) {
        auto t0 = std::chrono::steady_clock::now();
        kx_scene_draw(c, f, t, scene, (double)(i % 120) / 120.0);
        kx_flush_target(c, t);
        ts.push_back(std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count());
    }
    std::sort(ts.begin(), ts.end());
    return ts[ts.size() / 2];
}

// ---------------------------------------------------------------------------
// kx_draw v1 : accès internes (déclarés dans kx_internal.h)
// ---------------------------------------------------------------------------
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx* c) {
    return (c && c->backend == KX_BACKEND_GRAPHITE_VULKAN) ? c->recorder.get() : nullptr;
}
GrDirectContext* kx_ctx_gr_context(kx_ctx* c) {
    return (c && c->backend == KX_BACKEND_GANESH_GL) ? c->gr.get() : nullptr;
}
