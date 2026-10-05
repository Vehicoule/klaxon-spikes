// K3-parité — glue C++ minimal. La logique vit dans zig (gallery/main.zig
// exporte kx_gallery_main ; klaxon/host.zig pilote SDL). Ce fichier fournit :
//  - SDL_main classic → kx_gallery_main(argc, argv)
//  - kx_probe_intent_extra : lit un extra String de l'intent
//    ("kx_args" injecté dans argv côté Java par SDLActivity.getArguments)
//  - kx_ime_bottom/kx_ime_visible/kx_sysbar_top/kx_nav_bottom/kx_view_bottom /
//    kx_set_soft_input_mode : sondes WindowInsets Java (vérité #13166)
//  - pont a11y canonique : kx_a11y_sync_* (zig) → KxA11yProvider (Java,
//    AccessibilityNodeProvider TalkBack) + action handler ACTION_CLICK.
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_system.h>
#include <unordered_map>

#include <jni.h>
#include <cstring>

extern "C" int kx_gallery_main(int argc, char* argv[]);

int SDL_main(int argc, char* argv[]) { return kx_gallery_main(argc, argv); }

extern "C" {

// ---- sélection de probe via intent extras ----------------------------------
const char* kx_probe_intent_extra(const char* name) {
    static char cache[256];
    cache[0] = 0;
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jobject act = (jobject)SDL_GetAndroidActivity();
    if (!env || !act) return nullptr;
    jclass cls = env->GetObjectClass(act);
    jmethodID get_intent = env->GetMethodID(
        cls, "getIntent", "()Landroid/content/Intent;");
    if (!get_intent) { env->ExceptionClear(); return nullptr; }
    jobject intent = env->CallObjectMethod(act, get_intent);
    if (!intent) return nullptr;
    jclass icls = env->GetObjectClass(intent);
    jmethodID get_str = env->GetMethodID(
        icls, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!get_str) { env->ExceptionClear(); return nullptr; }
    jstring jname = env->NewStringUTF(name);
    jstring val = (jstring)env->CallObjectMethod(intent, get_str, jname);
    env->DeleteLocalRef(jname);
    env->DeleteLocalRef(cls);
    env->DeleteLocalRef(icls);
    env->DeleteLocalRef(intent);
    if (!val) return nullptr;
    const char* s = env->GetStringUTFChars(val, nullptr);
    std::strncpy(cache, s ? s : "", sizeof(cache) - 1);
    cache[sizeof(cache) - 1] = 0;
    if (s) env->ReleaseStringUTFChars(val, s);
    env->DeleteLocalRef(val);
    return cache[0] ? cache : nullptr;
}

// ---- sondes WindowInsets (classe org.libsdl.app.KxProbe) --------------------
static int call_kxprobe(const char* method) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jobject act = (jobject)SDL_GetAndroidActivity();
    if (!env || !act) return -1;
    jclass kls = env->FindClass("org/libsdl/app/KxProbe");
    if (!kls) { env->ExceptionClear(); return -1; }
    jmethodID m = env->GetStaticMethodID(kls, method, "(Landroid/app/Activity;)I");
    if (!m) {
        env->ExceptionClear();
        env->DeleteLocalRef(kls);
        return -1;
    }
    int r = env->CallStaticIntMethod(kls, m, act);
    env->DeleteLocalRef(kls);
    return r;
}
int kx_ime_bottom() { return call_kxprobe("imeBottom"); }
int kx_ime_visible() { return call_kxprobe("imeVisible"); }
int kx_sysbar_top() { return call_kxprobe("sysbarTop"); }
int kx_nav_bottom() { return call_kxprobe("navBottom"); }
int kx_view_bottom() { return call_kxprobe("viewBottom"); }
int kx_set_soft_input_mode(int mode) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jobject act = (jobject)SDL_GetAndroidActivity();
    if (!env || !act) return -1;
    jclass kls = env->FindClass("org/libsdl/app/KxProbe");
    if (!kls) { env->ExceptionClear(); return -1; }
    jmethodID m = env->GetStaticMethodID(kls, "setSoftInput", "(Landroid/app/Activity;I)I");
    if (!m) {
        env->ExceptionClear();
        env->DeleteLocalRef(kls);
        return -1;
    }
    int r = env->CallStaticIntMethod(kls, m, act, mode);
    env->DeleteLocalRef(kls);
    return r;
}

// ---- pont a11y canonique : kx_a11y_sync_* → KxA11yProvider (Java) ------------
// ABI figée : le zig pousse l'arbre à chaque frame ; ici on traduit en appels
// JNI vers les statiques onSyncBegin/onSyncItem/onSyncEnd du provider.
// ident (pointeur Node*, jamais déréférencé) ↔ nodeId Android stable via map.
static jclass kx_a11y_cls = nullptr;
static jmethodID kx_m_begin = nullptr, kx_m_item = nullptr, kx_m_end = nullptr;
static std::unordered_map<void*, jint> kx_id_of;
static std::unordered_map<jint, void*> kx_ident_of;
static jint kx_next_id = 1;
static void (*g_a11y_cb)(void*, void*, int) = nullptr;
static void* g_a11y_ctx = nullptr;

static jclass kx_a11y_class(JNIEnv* env) {
    if (kx_a11y_cls) return kx_a11y_cls;
    jclass c = env->FindClass("org/libsdl/app/KxA11yProvider");
    if (!c) { env->ExceptionClear(); return nullptr; }
    kx_a11y_cls = (jclass)env->NewGlobalRef(c);
    env->DeleteLocalRef(c);
    kx_m_begin = env->GetStaticMethodID(kx_a11y_cls, "onSyncBegin", "(F)V");
    kx_m_item = env->GetStaticMethodID(kx_a11y_cls,
        "onSyncItem", "(IILjava/lang/String;Ljava/lang/String;FFFFII)V");
    kx_m_end = env->GetStaticMethodID(kx_a11y_cls, "onSyncEnd", "()I");
    if (!kx_m_begin || !kx_m_item || !kx_m_end) env->ExceptionClear();
    return kx_a11y_cls;
}

int kx_a11y_sync_begin(void* /*view*/, double scale) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jclass c = env ? kx_a11y_class(env) : nullptr;
    if (!env || !c || !kx_m_begin) return 0;
    env->CallStaticVoidMethod(c, kx_m_begin, (jfloat)scale);
    return 0;
}

int kx_a11y_sync_item(void* /*view*/, void* ident, void* parent_ident,
                      int role, const char* label, const char* hint,
                      double x, double y, double w, double h, unsigned flags) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jclass c = env ? kx_a11y_class(env) : nullptr;
    if (!env || !c || !kx_m_item || !ident) return -1;
    jint id;
    auto it = kx_id_of.find(ident);
    if (it == kx_id_of.end()) {
        id = kx_next_id++;
        kx_id_of[ident] = id;
        kx_ident_of[id] = ident;
    } else {
        id = it->second;
    }
    jint pid = 0;
    if (parent_ident) {
        auto p = kx_id_of.find(parent_ident);
        if (p != kx_id_of.end()) pid = p->second;
    }
    jstring jl = env->NewStringUTF(label ? label : "");
    jstring jh = env->NewStringUTF(hint ? hint : "");
    env->CallStaticVoidMethod(c, kx_m_item, id, role, jl, jh,
                              (jfloat)x, (jfloat)y, (jfloat)w, (jfloat)h, flags, pid);
    env->DeleteLocalRef(jl);
    env->DeleteLocalRef(jh);
    return id;
}

int kx_a11y_sync_end(void* /*view*/) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    jclass c = env ? kx_a11y_class(env) : nullptr;
    if (!env || !c || !kx_m_end) return -1;
    return env->CallStaticIntMethod(c, kx_m_end);
}

void kx_a11y_set_action_handler(void* /*view*/,
                              void (*cb)(void*, void*, int), void* ctx) {
    g_a11y_cb = cb;
    g_a11y_ctx = ctx;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_KxA11yProvider_nativePerformAction(
    JNIEnv*, jclass, jint id, jint action) {
    if (!g_a11y_cb) return;
    auto it = kx_ident_of.find(id);
    if (it == kx_ident_of.end()) return;
    g_a11y_cb(g_a11y_ctx, it->second, (int)action);
}

// ---- MediaSession (ADR-0005) : commandes OS → zig ; état/meta zig → Java ----
// action figée : 0 play,1 pause,2 next,3 prev,4 seek(arg µs),5 stop.
// Le cb s'exécute sur le thread appelant JNI (binder/UI) — côté zig il ne fait
// qu'enregistrer un pending drainé sur le thread SDL (pattern a11y identique).

static void (*g_media_cb)(void*, int, long long) = nullptr;
static void* g_media_ctx = nullptr;

void kx_media_set_action_handler(void (*cb)(void*, int, long long), void* ctx) {
    g_media_cb = cb;
    g_media_ctx = ctx;
}

JNIEXPORT void JNICALL Java_org_libsdl_app_KxMediaSession_nativeMediaCommand(
    JNIEnv*, jclass, jint action, jlong arg) {
    if (g_media_cb) g_media_cb(g_media_ctx, (int)action, (long long)arg);
}

// state : 0 stopped,1 playing,2 paused ; pos/dur en µs ; speed 1.0
void kx_media_publish_state(int state, long long pos_us, double speed,
                            long long dur_us) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    if (!env) return;
    jclass c = env->FindClass("org/libsdl/app/KxMediaSession");
    if (!c) { env->ExceptionClear(); return; }
    jmethodID m = env->GetStaticMethodID(c, "publishState", "(IJDJ)V");
    if (m) env->CallStaticVoidMethod(c, m, (jint)state, (jlong)pos_us,
                                   (jdouble)speed, (jlong)dur_us);
    env->DeleteLocalRef(c);
}

void kx_media_publish_meta(const char* title, const char* artist,
                           long long dur_ms) {
    JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
    if (!env) return;
    jclass c = env->FindClass("org/libsdl/app/KxMediaSession");
    if (!c) { env->ExceptionClear(); return; }
    jmethodID m = env->GetStaticMethodID(c, "publishMeta",
                                       "(Ljava/lang/String;Ljava/lang/String;J)V");
    if (m) {
        jstring t = env->NewStringUTF(title ? title : "");
        jstring a = env->NewStringUTF(artist ? artist : "");
        env->CallStaticVoidMethod(c, m, t, a, (jlong)dur_ms);
        env->DeleteLocalRef(t);
        env->DeleteLocalRef(a);
    }
    env->DeleteLocalRef(c);
}

}  // extern "C"
