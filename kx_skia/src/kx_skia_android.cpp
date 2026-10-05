// kx_skia_android.cpp — platform file Android, canonical ABI (kx_skia.h).
// Ganesh GLES sur le contexte GL COURANT (SDL possède EGL/ctx/surface) +
// raster CPU + graphite Vulkan (K0) conservés pour complétude ABI.
// Internals (kx_internal.h) : kx_flush_target, kx_acquire_surface (no-op —
// surface posée à la création), kx_ctx_corpus_image, kx_ctx_gr_context,
// kx_ctx_graphite_recorder, kx_fonts_collection/families, stubs metal.
#include "kx_skia.h"
#include "kx_internal.h"

#include <dlfcn.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkData.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkFontTypes.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLFunctions.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/ganesh/SkImageGanesh.h"
#include "src/gpu/GpuTypesPriv.h"
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/graphite/vk/VulkanGraphiteTypes.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanPreferredFeatures.h"
#include "include/ports/SkFontMgr_empty.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "src/gpu/vk/VulkanInterface.h"
#include "src/gpu/vk/vulkanmemoryallocator/VulkanAMDMemoryAllocator.h"

using skgpu::Mipmapped;

// ---------------------------------------------------------------------------
// Fontes — SkFontMgr_New_Custom_Empty().makeFromData n'indexe pas les familles
// (piège W0 n°5) : on fabrique les faces avec le mgr vide puis on ré-indexe
// par nom de famille dans KxFontMgr, avec fallback par couverture unichar.
// ---------------------------------------------------------------------------
namespace {

class KxFontMgr : public SkFontMgr {
public:
    explicit KxFontMgr(sk_sp<SkFontMgr> fabricator) : fFab(std::move(fabricator)) {}

    void addFace(sk_sp<SkTypeface> face) {
        if (!face) return;
        SkString name;
        face->getFamilyName(&name);
        fFaces.push_back({std::move(face), name});
    }

    const std::vector<SkString>& families() const {
        if (!fFamiliesReady) {
            fFamilies.clear();
            for (auto& f : fFaces) {
                if (std::none_of(fFamilies.begin(), fFamilies.end(),
                                 [&](const SkString& s) { return s == f.second; })) {
                    fFamilies.push_back(f.second);
                }
            }
            fFamiliesReady = true;
        }
        return fFamilies;
    }

protected:
    int onCountFamilies() const override { return (int)this->families().size(); }

    void onGetFamilyName(int index, SkString* familyName) const override {
        auto& fams = this->families();
        *familyName = (index >= 0 && index < (int)fams.size()) ? fams[index] : SkString();
    }

    sk_sp<SkFontStyleSet> onCreateStyleSet(int index) const override { return nullptr; }

    sk_sp<SkFontStyleSet> onMatchFamily(const char familyName[]) const override {
        return nullptr;
    }

    sk_sp<SkTypeface> onMatchFamilyStyle(const char familyName[],
                                         const SkFontStyle&) const override {
        if (familyName) {
            for (auto& f : fFaces) {
                if (f.second.equals(familyName)) return f.first;
            }
        }
        return fFaces.empty() ? nullptr : fFaces[0].first;
    }

    sk_sp<SkTypeface> onMatchFamilyStyleCharacter(const char familyName[],
                                                  const SkFontStyle& style,
                                                  const char* bcp47[], int bcp47Count,
                                                  SkUnichar character) const override {
        for (auto& f : fFaces) {
            if (f.first->unicharToGlyph(character)) {
                if (familyName && f.second.equals(familyName)) return f.first;
                if (!familyName) return f.first;
            }
        }
        for (auto& f : fFaces) {
            if (f.first->unicharToGlyph(character)) return f.first;
        }
        return fFaces.empty() ? nullptr : fFaces[0].first;
    }

    sk_sp<SkTypeface> onMakeFromData(sk_sp<SkData> d, int ttc) const override {
        return fFab->makeFromData(std::move(d), ttc);
    }
    sk_sp<SkTypeface> onMakeFromStreamIndex(std::unique_ptr<SkStreamAsset> s,
                                            int ttc) const override {
        return fFab->makeFromStream(std::move(s), ttc);
    }
    sk_sp<SkTypeface> onMakeFromStreamArgs(std::unique_ptr<SkStreamAsset> s,
                                           const SkFontArguments& a) const override {
        return fFab->makeFromStream(std::move(s), a);
    }
    sk_sp<SkTypeface> onMakeFromFile(const char p[], int ttc) const override {
        return fFab->makeFromFile(p, ttc);
    }
    sk_sp<SkTypeface> onLegacyMakeTypeface(const char familyName[],
                                           SkFontStyle style) const override {
        return this->onMatchFamilyStyle(familyName, style);
    }

private:
    struct Face { sk_sp<SkTypeface> first; SkString second; };
    std::vector<Face> fFaces;
    sk_sp<SkFontMgr> fFab;
    mutable std::vector<SkString> fFamilies;
    mutable bool fFamiliesReady = false;
};

}  // namespace

struct kx_fonts {
    sk_sp<SkFontMgr> fabricator = SkFontMgr_New_Custom_Empty();
    sk_sp<KxFontMgr> mgr = sk_make_sp<KxFontMgr>(fabricator);
    sk_sp<skia::textlayout::FontCollection> collection =
        sk_make_sp<skia::textlayout::FontCollection>();
    std::vector<SkString> families;
};

skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts* f) {
    return f ? f->collection.get() : nullptr;
}
const std::vector<SkString>* kx_fonts_families(kx_fonts* f) {
    return f ? &f->families : nullptr;
}

kx_fonts* kx_fonts_global() {
    static kx_fonts* g = new kx_fonts();
    return g;
}

int kx_fonts_add(kx_fonts* f, const void* data, size_t len) {
    if (!f || !data || !len) return -1;
    int added = 0;
    // Tolère TTC : tente des indices 0..15 jusqu'à échec.
    for (int i = 0; i < 16; ++i) {
        auto tf = f->fabricator->makeFromData(SkData::MakeWithCopy(data, len), i);
        if (!tf) break;
        f->mgr->addFace(tf);
        SkString n;
        tf->getFamilyName(&n);
        if (std::none_of(f->families.begin(), f->families.end(),
                         [&](const SkString& s) { return s == n; })) {
            f->families.push_back(n);
        }
        ++added;
    }
    if (!added) return -1;
    f->collection->setAssetFontManager(f->mgr);
    f->collection->enableFontFallback();
    return (int)f->families.size() - 1;
}

int kx_fonts_count(const kx_fonts* f) { return f ? (int)f->families.size() : 0; }

void kx_fonts_free(kx_fonts* f) { delete f; }

int kx_fonts_family_index(const kx_fonts* f, const char* name) {
    if (!f || !name) return -1;
    for (size_t i = 0; i < f->families.size(); ++i)
        if (f->families[i].equals(name)) return (int)i;
    return -1;
}

// Scan récursif .ttf/.otf/.ttc (POSIX — port de kx_skia_linux.cpp).
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
    kx_backend backend = KX_BACKEND_RASTER;
    std::string driver;

    sk_sp<GrDirectContext> grctx;
    bool external_gl = false; // ganesh_gl_current : EGL possédé par l'hôte

    // graphite vulkan
    void* vk_lib = nullptr;
    VkInstance vk_inst = VK_NULL_HANDLE;
    VkPhysicalDevice vk_phys = VK_NULL_HANDLE;
    VkDevice vk_dev = VK_NULL_HANDLE;
    VkQueue vk_queue = VK_NULL_HANDLE;
    uint32_t vk_qidx = 0;
    uint32_t vk_api = VK_API_VERSION_1_1;
    skgpu::VulkanExtensions vk_ext;
    VkPhysicalDeviceFeatures2 vk_feat2 = {};
    skgpu::VulkanBackendContext vk_backend = {};
    sk_sp<skgpu::VulkanInterface> vk_iface;
    std::unique_ptr<skgpu::graphite::Context> gctx;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    std::deque<std::unique_ptr<skgpu::graphite::Recording>> recordings;

    sk_sp<SkImage> corpus_img;
};

// ---- internes kx_internal.h -------------------------------------------------
GrDirectContext* kx_ctx_gr_context(kx_ctx* c) { return c ? c->grctx.get() : nullptr; }
skgpu::graphite::Recorder* kx_ctx_graphite_recorder(kx_ctx* c) {
    return (c && c->recorder) ? c->recorder.get() : nullptr;
}
int kx_graphite_canvas_acquire(kx_target*) { return -1; } // pas de graphite webgpu natif
int kx_metal_acquire(kx_target*) { return -1; }
int kx_metal_present(kx_target*) { return -1; }

// ---- raster -----------------------------------------------------------------
kx_ctx* kx_ctx_create_raster() {
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_RASTER;
    c->driver = "raster-cpu(skia-cpu)";
    return c;
}

// ---- ganesh GLES : contexte GL courant de l'hôte (SDL) -----------------------
// get_proc = SDL_GL_GetProcAddress (ou équivalent). Ne possède PAS le ctx EGL :
// l'hôte reste propriétaire — kx_ctx_free ne touche pas à EGL.
// GrGLGetProc = void (*(*)(void* ctx, const char* name))() — notre ABI est
// void* (*)(const char*) : le ctx transporte le callback kx.
static void (*kx_gl_getproc_adapter(void* ctx, const char* name))() {
    auto get = reinterpret_cast<kx_gl_getproc>(ctx);
    return reinterpret_cast<void (*)()>(get ? get(name) : nullptr);
}
kx_ctx* kx_ctx_create_ganesh_gl_current(kx_gl_getproc get_proc) {
    if (!get_proc) return nullptr;
    sk_sp<const GrGLInterface> iface = GrGLMakeAssembledGLESInterface(
        reinterpret_cast<void*>(get_proc), &kx_gl_getproc_adapter);
    if (!iface) {
        fprintf(stderr, "[kx] ganesh-gl-current: GrGLMakeAssembledGLESInterface null\n");
        return nullptr;
    }
    sk_sp<GrDirectContext> gctx = GrDirectContexts::MakeGL(iface);
    if (!gctx) {
        fprintf(stderr, "[kx] ganesh-gl-current: MakeGL null\n");
        return nullptr;
    }
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_GANESH_GL;
    c->grctx = std::move(gctx);
    c->external_gl = true;
    const char* rend = (const char*)glGetString(GL_RENDERER);
    const char* ver = (const char*)glGetString(GL_VERSION);
    const char* vend = (const char*)glGetString(GL_VENDOR);
    char buf[512];
    snprintf(buf, sizeof(buf), "ganesh-gles(%s; %s; %s)",
             vend ? vend : "?", rend ? rend : "?", ver ? ver : "?");
    c->driver = buf;
    return c;
}

// ---- graphite vulkan (K0 — conservé ; indisponible <~API33-35 sur émulateur) -
namespace {

PFN_vkGetInstanceProcAddr g_gipa = nullptr;
PFN_vkGetDeviceProcAddr g_gdpa = nullptr;
PFN_vkVoidFunction vk_get_proc(const char* name, VkInstance inst,
                               VkDevice dev) {
    if (!g_gipa) return nullptr;
    if (dev != VK_NULL_HANDLE && g_gdpa) {
        if (auto p = g_gdpa(dev, name)) return (PFN_vkVoidFunction)p;
    }
    return (PFN_vkVoidFunction)g_gipa(inst, name);
}

const char* vk_ver(uint32_t v) {
    static char b[32];
    snprintf(b, sizeof(b), "%u.%u.%u", VK_VERSION_MAJOR(v), VK_VERSION_MINOR(v),
             VK_VERSION_PATCH(v));
    return b;
}

}  // namespace

kx_ctx* kx_ctx_create_graphite_vulkan() {
    auto* c = new kx_ctx();
    c->backend = KX_BACKEND_GRAPHITE_VULKAN;
    c->vk_lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!c->vk_lib) c->vk_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!c->vk_lib) { delete c; return nullptr; }
    auto gipa =
        (PFN_vkGetInstanceProcAddr)dlsym(c->vk_lib, "vkGetInstanceProcAddr");
    if (!gipa) { delete c; return nullptr; }
    auto enumVer =
        (PFN_vkEnumerateInstanceVersion)gipa(nullptr, "vkEnumerateInstanceVersion");
    uint32_t instVer = VK_API_VERSION_1_1;
    if (enumVer) enumVer(&instVer);
    c->vk_api = std::min(instVer, (uint32_t)VK_API_VERSION_1_3);

    auto pfnCreateInstance =
        (PFN_vkCreateInstance)gipa(nullptr, "vkCreateInstance");
    if (!pfnCreateInstance) { delete c; return nullptr; }

    skgpu::VulkanPreferredFeatures skiaFeat;
    skiaFeat.init(c->vk_api);

    auto pfnEnumInstExt = (PFN_vkEnumerateInstanceExtensionProperties)gipa(
        nullptr, "vkEnumerateInstanceExtensionProperties");
    uint32_t nExt = 0;
    std::vector<VkExtensionProperties> instExts;
    if (pfnEnumInstExt) {
        pfnEnumInstExt(nullptr, &nExt, nullptr);
        instExts.resize(nExt);
        pfnEnumInstExt(nullptr, &nExt, instExts.data());
    }
    std::vector<const char*> wantInst;
    skiaFeat.addToInstanceExtensions(instExts.data(), instExts.size(), wantInst);

    VkApplicationInfo app = {};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "kx-corpus";
    app.apiVersion = c->vk_api;
    VkInstanceCreateInfo ici = {};
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = (uint32_t)wantInst.size();
    ici.ppEnabledExtensionNames = wantInst.data();
    if (pfnCreateInstance(&ici, nullptr, &c->vk_inst) != VK_SUCCESS) {
        delete c;
        return nullptr;
    }
    g_gipa = gipa;
    g_gdpa = (PFN_vkGetDeviceProcAddr)gipa(c->vk_inst, "vkGetDeviceProcAddr");

    auto pfnEnumPhys = (PFN_vkEnumeratePhysicalDevices)gipa(
        c->vk_inst, "vkEnumeratePhysicalDevices");
    uint32_t nPhys = 0;
    pfnEnumPhys(c->vk_inst, &nPhys, nullptr);
    if (!nPhys) { delete c; return nullptr; }
    std::vector<VkPhysicalDevice> phys(nPhys);
    pfnEnumPhys(c->vk_inst, &nPhys, phys.data());

    auto pfnGetProps = (PFN_vkGetPhysicalDeviceProperties)gipa(
        c->vk_inst, "vkGetPhysicalDeviceProperties");
    auto pfnGetQueue = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)gipa(
        c->vk_inst, "vkGetPhysicalDeviceQueueFamilyProperties");
    auto pfnEnumDevExt = (PFN_vkEnumerateDeviceExtensionProperties)gipa(
        c->vk_inst, "vkEnumerateDeviceExtensionProperties");
    auto pfnGetFeat2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(
        c->vk_inst, "vkGetPhysicalDeviceFeatures2");
    auto pfnCreateDev =
        (PFN_vkCreateDevice)gipa(c->vk_inst, "vkCreateDevice");
    auto pfnGetDevQueue =
        (PFN_vkGetDeviceQueue)gipa(c->vk_inst, "vkGetDeviceQueue");
    if (!pfnEnumPhys || !pfnGetProps || !pfnGetQueue || !pfnEnumDevExt ||
        !pfnCreateDev || !pfnGetDevQueue) {
        delete c;
        return nullptr;
    }

    VkPhysicalDevice chosen = VK_NULL_HANDLE;
    uint32_t chosenQ = ~0u;
    VkPhysicalDeviceProperties chosenProps = {};
    int best = -1;
    for (auto p : phys) {
        VkPhysicalDeviceProperties pr;
        pfnGetProps(p, &pr);
        uint32_t nq = 0;
        pfnGetQueue(p, &nq, nullptr);
        std::vector<VkQueueFamilyProperties> qs(nq);
        pfnGetQueue(p, &nq, qs.data());
        int qi = -1;
        for (uint32_t i = 0; i < nq; ++i)
            if (qs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { qi = (int)i; break; }
        if (qi < 0) continue;
        int score = (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)   ? 3
                    : (pr.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) ? 2
                                                                              : 1;
        if (score > best) {
            best = score;
            chosen = p;
            chosenQ = (uint32_t)qi;
            chosenProps = pr;
        }
    }
    if (!chosen) {
        fprintf(stderr, "[kx] vulkan: aucun device avec queue graphique\n");
        delete c;
        return nullptr;
    }
    c->vk_phys = chosen;
    c->vk_qidx = chosenQ;
    c->vk_api = std::min(c->vk_api, chosenProps.apiVersion);

    uint32_t nde = 0;
    pfnEnumDevExt(chosen, nullptr, &nde, nullptr);
    std::vector<VkExtensionProperties> devExts(nde);
    pfnEnumDevExt(chosen, nullptr, &nde, devExts.data());

    VkPhysicalDeviceFeatures2 feat2 = {};
    feat2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    skiaFeat.init(c->vk_api);
    skiaFeat.addFeaturesToQuery(devExts.data(), devExts.size(), feat2);
    if (pfnGetFeat2) pfnGetFeat2(chosen, &feat2);

    std::vector<const char*> wantDev;
    skiaFeat.addFeaturesToEnable(wantDev, feat2);

    float prio = 1.f;
    VkDeviceQueueCreateInfo qi = {};
    qi.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qi.queueFamilyIndex = chosenQ;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci = {};
    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qi;
    dci.pNext = &feat2;
    dci.enabledExtensionCount = (uint32_t)wantDev.size();
    dci.ppEnabledExtensionNames = wantDev.data();
    VkResult dres = pfnCreateDev(chosen, &dci, nullptr, &c->vk_dev);
    if (dres != VK_SUCCESS) {
        fprintf(stderr, "[kx] vulkan: vkCreateDevice -> %d\n", (int)dres);
        delete c;
        return nullptr;
    }
    pfnGetDevQueue(c->vk_dev, chosenQ, 0, &c->vk_queue);

    skgpu::VulkanGetProc getProc = vk_get_proc;
    c->vk_ext.init(getProc, c->vk_inst, c->vk_phys, (uint32_t)wantInst.size(),
                   wantInst.data(), (uint32_t)wantDev.size(), wantDev.data());
    c->vk_iface = sk_make_sp<skgpu::VulkanInterface>(
        getProc, c->vk_inst, c->vk_dev, instVer, chosenProps.apiVersion,
        &c->vk_ext);
    if (!c->vk_iface->validate(instVer, chosenProps.apiVersion, &c->vk_ext)) {
        fprintf(stderr, "[kx] vulkan: VulkanInterface::validate échoué\n");
        delete c;
        return nullptr;
    }

    c->vk_backend.fInstance = c->vk_inst;
    c->vk_backend.fPhysicalDevice = c->vk_phys;
    c->vk_backend.fDevice = c->vk_dev;
    c->vk_backend.fQueue = c->vk_queue;
    c->vk_backend.fGraphicsQueueIndex = c->vk_qidx;
    c->vk_backend.fMaxAPIVersion = c->vk_api;
    c->vk_backend.fVkExtensions = &c->vk_ext;
    c->vk_feat2 = feat2;
    c->vk_backend.fDeviceFeatures2 = &c->vk_feat2;
    c->vk_backend.fGetProc = getProc;
    c->vk_backend.fMemoryAllocator = skgpu::VulkanAMDMemoryAllocator::Make(
        c->vk_inst, c->vk_phys, c->vk_dev, &c->vk_ext, c->vk_iface.get(),
        skgpu::ThreadSafe::kYes);

    skgpu::graphite::ContextOptions opts;
    auto g = skgpu::graphite::ContextFactory::MakeVulkan(c->vk_backend, opts);
    if (!g) {
        fprintf(stderr, "[kx] vulkan: graphite ContextFactory::MakeVulkan a échoué\n");
        delete c;
        return nullptr;
    }
    c->gctx = std::move(g);
    c->recorder = c->gctx->makeRecorder();

    const char* dtype =
        chosenProps.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU    ? "discrete"
        : chosenProps.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU ? "integrated"
        : chosenProps.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU             ? "cpu(swiftshader/lavapipe)"
        : chosenProps.deviceType == VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU     ? "virtual"
                                                                          : "other";
    char buf[512];
    snprintf(buf, sizeof(buf), "graphite-vulkan(%s; api %s; %s)",
             chosenProps.deviceName, vk_ver(chosenProps.apiVersion), dtype);
    c->driver = buf;
    return c;
}

kx_ctx* kx_ctx_create_graphite_dawn() { return nullptr; }
kx_ctx* kx_ctx_create_graphite_dawn_d3d12() { return nullptr; }
kx_ctx* kx_ctx_create_graphite_dawn_vulkan() { return nullptr; }
kx_ctx* kx_ctx_create_graphite_metal() { return nullptr; }
kx_ctx* kx_ctx_create_graphite_webgpu() { return nullptr; }
kx_ctx* kx_ctx_create_ganesh_webgl(const char*) { return nullptr; }
kx_ctx* kx_ctx_create_ganesh_gl() { return nullptr; } // pbuffer EGL K0 : inutilisé en app

kx_backend kx_ctx_backend(const kx_ctx* c) { return c ? c->backend : KX_BACKEND_RASTER; }
const char* kx_ctx_driver_info(const kx_ctx* c) { return c ? c->driver.c_str() : ""; }

int kx_ctx_has_unfinished_work(kx_ctx* c) {
    if (!c) return 0;
    return (c->gctx && c->gctx->hasUnfinishedGpuWork()) ? 1 : 0;
}

void kx_ctx_free(kx_ctx* c) {
    if (!c) return;
    if (c->gctx) {
        c->gctx->submit(skgpu::graphite::SubmitInfo(skgpu::graphite::SyncToCpu::kYes));
    }
    c->recordings.clear();
    c->recorder.reset();
    c->gctx.reset();
    c->grctx.reset(); // external_gl : on ne détruit PAS le ctx EGL de l'hôte
    if (c->vk_dev != VK_NULL_HANDLE && g_gdpa) {
        auto waitIdle = (PFN_vkDeviceWaitIdle)g_gdpa(c->vk_dev, "vkDeviceWaitIdle");
        auto destroyDev = (PFN_vkDestroyDevice)g_gdpa(c->vk_dev, "vkDestroyDevice");
        if (waitIdle) waitIdle(c->vk_dev);
        if (destroyDev) destroyDev(c->vk_dev, nullptr);
    }
    if (c->vk_inst != VK_NULL_HANDLE && g_gipa) {
        auto destroyInst =
            (PFN_vkDestroyInstance)g_gipa(c->vk_inst, "vkDestroyInstance");
        if (destroyInst) destroyInst(c->vk_inst, nullptr);
    }
    if (c->vk_lib) dlclose(c->vk_lib);
    delete c;
}

// ---- cibles -----------------------------------------------------------------
kx_target* kx_target_offscreen(kx_ctx* c, int w, int h) {
    if (!c) return nullptr;
    auto* t = new kx_target();
    t->ctx = c;
    t->w = w;
    t->h = h;
    auto info =
        SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType,
                          SkColorSpace::MakeSRGB());
    switch (c->backend) {
        case KX_BACKEND_RASTER:
            t->surface = SkSurfaces::Raster(info);
            break;
        case KX_BACKEND_GANESH_GL:
            t->surface = SkSurfaces::RenderTarget(
                c->grctx.get(), skgpu::Budgeted::kYes, info, 0,
                kTopLeft_GrSurfaceOrigin, nullptr);
            break;
        case KX_BACKEND_GRAPHITE_VULKAN:
            if (!c->recorder) c->recorder = c->gctx->makeRecorder();
            t->surface = SkSurfaces::RenderTarget(c->recorder.get(), info,
                                                  Mipmapped::kNo, nullptr);
            break;
        default:
            break;
    }
    if (!t->surface) { delete t; return nullptr; }
    return t;
}

// Canonical : wrap du framebuffer GL courant (FBO lié au moment de l'appel —
// SDL pose FBO 0 pour la fenêtre). Recréer après resize/surfaceDestroyed.
kx_target* kx_target_onscreen_gl(kx_ctx* c, int w, int h) {
    if (!c || c->backend != KX_BACKEND_GANESH_GL || w <= 0 || h <= 0) return nullptr;
    GLint fbo = 0, stencil = 0, samples = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
    glGetIntegerv(GL_STENCIL_BITS, &stencil);
    glGetIntegerv(GL_SAMPLES, &samples);
    GrGLFramebufferInfo info{};
    info.fFBOID = (GrGLuint)fbo;
    info.fFormat = GL_RGBA8;
    auto rt = GrBackendRenderTargets::MakeGL(w, h, samples, stencil, info);
    auto surf = SkSurfaces::WrapBackendRenderTarget(
        c->grctx.get(), rt, kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType,
        SkColorSpace::MakeSRGB(), nullptr);
    if (!surf) {
        fprintf(stderr, "[kx] onscreen_gl: WrapBackendRenderTarget null (fbo=%d)\n", fbo);
        return nullptr;
    }
    auto* t = new kx_target();
    t->ctx = c;
    t->surface = std::move(surf);
    t->w = w;
    t->h = h;
    t->onscreen = true;
    t->gl_fbo = (unsigned)fbo;
    return t;
}

kx_target* kx_target_canvas(kx_ctx*, const char*, int, int) { return nullptr; }
kx_target* kx_target_onscreen_dawn(kx_ctx*, void*, int, int) { return nullptr; }
kx_target* kx_target_onscreen_metal(kx_ctx*, void*, int, int, double) { return nullptr; }

void kx_target_free(kx_target* t) { delete t; }
void kx_target_size(const kx_target* t, int* w, int* h) {
    if (w) *w = t->w;
    if (h) *h = t->h;
}

// Canonical internals : flush des commandes enregistrées + submit.
int kx_flush_target(kx_ctx* c, kx_target* t) {
    if (!c) return -1;
    if (c->backend == KX_BACKEND_GANESH_GL) {
        if (t && t->surface) c->grctx->flush(t->surface.get());
        c->grctx->submit(GrSyncCpu::kNo);
        return 0;
    }
    if (c->backend == KX_BACKEND_GRAPHITE_VULKAN) {
        auto rec = c->recorder->snap();
        if (rec) {
            skgpu::graphite::InsertRecordingInfo info = {};
            info.fRecording = rec.get();
            auto st = c->gctx->insertRecording(info);
            if (!st) return -2;
            c->recordings.push_back(std::move(rec));
        }
        c->gctx->submit();
        return 0;
    }
    return 0;
}

// Acquisition paresseuse de la surface : no-op — toutes nos cibles posent
// leur SkSurface à la création (pas de swapchain à interroger par frame).
int kx_acquire_surface(kx_target* t) {
    return (t && t->surface) ? 0 : -1;
}

// Présentation : flush seulement — SDL_GL_SwapWindow présente après (hôte).
int kx_present(kx_ctx* c, kx_target* t) { return kx_flush_target(c, t); }

// ---- image corpus déterministe (damier 64×64) ------------------------------
sk_sp<SkImage> kx_ctx_corpus_image(kx_ctx* c) {
    if (!c) return nullptr;
    if (c->corpus_img) return c->corpus_img;
    SkBitmap bm;
    bm.allocPixels(SkImageInfo::Make(64, 64, kRGBA_8888_SkColorType,
                                   kPremul_SkAlphaType, SkColorSpace::MakeSRGB()));
    bm.eraseColor(SK_ColorWHITE);
    SkCanvas cv(bm);
    SkPaint p;
    for (int y = 0; y < 8; ++y)
        for (int x = 0; x < 8; ++x) {
            SkColor col = ((x + y) & 1) ? 0xFF2E86AB : 0xFFF6F5AE;
            if ((x ^ y) & 3) col ^= 0x00183A5F;
            p.setColor(col);
            cv.drawRect(SkRect::MakeXYWH(x * 8, y * 8, 8, 8), p);
        }
    auto img = bm.asImage();
    if (c->backend == KX_BACKEND_GRAPHITE_VULKAN) {
        auto tex = SkImages::TextureFromImage(c->recorder.get(), img.get(), {});
        if (tex) img = tex;
    } else if (c->backend == KX_BACKEND_GANESH_GL) {
        auto tex = SkImages::TextureFromImage(c->grctx.get(), img.get());
        if (tex) img = tex;
    }
    c->corpus_img = img;
    return img;
}

// ---- readback ----------------------------------------------------------------
struct kx_readback {
    int w = 0, h = 0;
    std::vector<uint8_t> pixels;
    std::atomic<int> state{0};  // 0 pending, 1 ready, <0 fail
    SkImageInfo info;
};

static void rb_callback(kx_readback* rb,
                        std::unique_ptr<const SkImage::AsyncReadResult> res) {
    if (!res || !res->count()) {
        rb->state.store(-1);
        return;
    }
    const size_t rowBytes = res->rowBytes(0);
    const size_t minRow = (size_t)rb->w * 4;
    if (rowBytes < minRow) {
        rb->state.store(-2);
        return;
    }
    for (int y = 0; y < rb->h; ++y)
        memcpy(rb->pixels.data() + y * minRow,
               (const uint8_t*)res->data(0) + y * rowBytes, minRow);
    rb->state.store(1);
}

kx_readback* kx_readback_start(kx_ctx* c, kx_target* t) {
    if (!c || !t || !t->surface) return nullptr;
    auto* rb = new kx_readback();
    rb->w = t->w;
    rb->h = t->h;
    rb->pixels.resize((size_t)t->w * t->h * 4);
    rb->info = SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                 kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
    switch (c->backend) {
        case KX_BACKEND_RASTER: {
            SkPixmap pm(rb->info, rb->pixels.data(), (size_t)t->w * 4);
            rb->state.store(t->surface->readPixels(pm, 0, 0) ? 1 : -3);
            break;
        }
        case KX_BACKEND_GANESH_GL: {
            c->grctx->flush(t->surface.get());
            c->grctx->submit(GrSyncCpu::kYes);
            SkPixmap pm(rb->info, rb->pixels.data(), (size_t)t->w * 4);
            rb->state.store(t->surface->readPixels(pm, 0, 0) ? 1 : -3);
            break;
        }
        case KX_BACKEND_GRAPHITE_VULKAN: {
            if (kx_flush_target(c, t) != 0) {
                rb->state.store(-4);
                break;
            }
            SkIRect rect = SkIRect::MakeWH(t->w, t->h);
            c->gctx->asyncRescaleAndReadPixels(
                t->surface.get(), rb->info, rect, SkImage::RescaleGamma::kSrc,
                SkImage::RescaleMode::kNearest,
                [](SkImage::ReadPixelsContext rctx,
                   std::unique_ptr<const SkImage::AsyncReadResult> res) {
                    rb_callback(static_cast<kx_readback*>(rctx), std::move(res));
                },
                rb);
            if (rb->state.load() == 0) c->gctx->submit();
            break;
        }
        default:
            rb->state.store(-5);
    }
    return rb;
}

int kx_readback_poll(kx_ctx* c, kx_readback* rb) {
    if (!rb) return -1;
    int st = rb->state.load();
    if (st != 0) return st;
    if (c && c->gctx) {
        c->gctx->checkAsyncWorkCompletion();
        st = rb->state.load();
        if (st == 0 && !c->gctx->hasUnfinishedGpuWork()) {
            c->gctx->checkAsyncWorkCompletion();
            st = rb->state.load();
        }
    }
    return st;
}

int kx_readback_copy(const kx_readback* rb, uint8_t* dst) {
    if (!rb || rb->state.load() != 1 || !dst) return -1;
    memcpy(dst, rb->pixels.data(), rb->pixels.size());
    return (int)rb->pixels.size();
}

int64_t kx_readback_copy_n(const kx_readback* rb, void* dst, size_t len) {
    if (!rb || rb->state.load() != 1 || !dst) return -1;
    const size_t n = std::min(len, rb->pixels.size());
    memcpy(dst, rb->pixels.data(), n);
    return (int64_t)n;
}

void kx_readback_free(kx_readback* rb) { delete rb; }

// ---- bench -------------------------------------------------------------------
static double bench_iter_ms(kx_ctx* c, kx_fonts* f, kx_target* t, int scene,
                            double phase) {
    auto t0 = std::chrono::steady_clock::now();
    if (kx_scene_draw(c, f, t, scene, phase) != 0) return -1;
    if (kx_flush_target(c, t) != 0) return -1;
    if (c->backend == KX_BACKEND_GRAPHITE_VULKAN) {
        c->gctx->submit(skgpu::graphite::SubmitInfo(skgpu::graphite::SyncToCpu::kYes));
        c->recordings.clear();
    } else {
        std::vector<uint8_t> tmp((size_t)t->w * t->h * 4);
        SkPixmap pm(SkImageInfo::Make(t->w, t->h, kRGBA_8888_SkColorType,
                                      kPremul_SkAlphaType, nullptr),
                    tmp.data(), t->w * 4);
        t->surface->readPixels(pm, 0, 0);
        if (c->backend == KX_BACKEND_GANESH_GL) c->grctx->submit(GrSyncCpu::kYes);
    }
    auto t1 = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

double kx_bench_ms(kx_ctx* c, kx_fonts* f, kx_target* t, int scene, int iters) {
    if (!c || !t) return -1;
    std::vector<double> ts;
    ts.reserve(iters);
    for (int i = 0; i < iters; ++i) {
        double ms = bench_iter_ms(c, f, t, scene, (double)i / iters);
        if (ms < 0) return -1;
        ts.push_back(ms);
    }
    std::sort(ts.begin(), ts.end());
    return ts[ts.size() / 2];
}
