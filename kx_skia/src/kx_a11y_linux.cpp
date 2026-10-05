// kx_a11y_linux.cpp — pont accessibilité Linux : AT-SPI2 via sd-bus brut.
//
// AT-SPI2 est un protocole D-Bus : l'app expose des objets
// org.a11y.atspi.{Application,Accessible,Component,Action} sur le bus a11y
// (adresse via AT_SPI_BUS_ADDRESS ou org.a11y.Bus.GetAddress sur le bus de
// session), puis s'enregistre auprès du registry daemon :
//   org.a11y.atspi.Registry /org/a11y/atspi/accessible/root
//   → org.a11y.atspi.Socket.Embed((s bus_name, o root_path))
//
// Zéro dépendance build : libsystemd est chargée par dlopen et les types
// sd-bus utilisés sont déclarés à la main (l'ABI est stable et publique).
// Si libsystemd est absente → pont désactivé, no-op.

#include "kx_skia.h"   // contrat public seul — ce fichier n'a pas besoin de Skia
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mutex>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Types sd-bus minimaux (ABI stable, reflète <systemd/sd-bus*.h>)
// ---------------------------------------------------------------------------
extern "C" {
typedef struct sd_bus sd_bus;
typedef struct sd_bus_slot sd_bus_slot;
typedef struct sd_bus_message sd_bus_message;
typedef struct sd_bus_error {
    const char* name;
    const char* message;
    int _need_free;
} sd_bus_error;
typedef int (*sd_bus_message_handler_t)(sd_bus_message*, void*, sd_bus_error*);
typedef int (*sd_bus_property_get_t)(sd_bus*, const char*, const char*,
                                     const char*, sd_bus_message*, void*,
                                     sd_bus_error*);
typedef int (*sd_bus_property_set_t)(sd_bus*, const char*, const char*,
                                     const char*, sd_bus_message*, void*,
                                     sd_bus_error*);
typedef int (*sd_bus_object_find_t)(sd_bus*, const char*, const char*, void*,
                                    void**, sd_bus_error*);
typedef struct sd_bus_vtable {
    uint64_t header; // octet 0 = type ('<','>','M','S','P','W'), reste = flags
    union {
        struct { size_t element_size; uint64_t features;
                 const unsigned* vtable_format_reference; } start;
        struct { size_t reserved; } end;
        struct { const char* member; const char* signature; const char* result;
                 sd_bus_message_handler_t handler; size_t offset;
                 const char* names; } method;
        struct { const char* member; const char* signature;
                 const char* names; } signal;
        struct { const char* member; const char* signature;
                 sd_bus_property_get_t get; sd_bus_property_set_t set;
                 size_t offset; } property;
    } x;
} sd_bus_vtable;
}

// features=1 (_SD_BUS_VTABLE_PARAM_NAMES) + format_reference = l'export
// sd_bus_object_vtable_format — sd-bus exige ce pointeur non-nul pour
// valider la table (sinon add_fallback_vtable → EINVAL silencieux).
#define VT_START   { .header = '<', .x = { .start = { sizeof(sd_bus_vtable), 1, nullptr } } }
#define VT_END     { .header = '>', .x = { .end = { 0 } } }
#define VT_METHOD(mem, sig, res, h)                                     \
    { .header = 'M', .x = { .method = { mem, sig, res, h, 0, "" } } }
#define VT_PROP(mem, sig, g)                                            \
    { .header = 'P', .x = { .property = { mem, sig, g, nullptr, 0 } } }
#define VT_PROP_W(mem, sig, g, s)                                       \
    { .header = 'W', .x = { .property = { mem, sig, g, s, 0 } } }

// ---------------------------------------------------------------------------
// Résolution dlopen
// ---------------------------------------------------------------------------
#define SYM(name) decltype(&name) p_##name = nullptr
static struct {
    void* lib;
    const unsigned* vtable_format_ref; // &sd_bus_object_vtable_format
    int (*sd_bus_new)(sd_bus**);
    int (*sd_bus_set_address)(sd_bus*, const char*);
    int (*sd_bus_set_bus_client)(sd_bus*, int);
    int (*sd_bus_start)(sd_bus*);
    int (*sd_bus_open_user)(sd_bus**);
    int (*sd_bus_unref)(sd_bus*);
    int (*sd_bus_flush)(sd_bus*);
    int (*sd_bus_process)(sd_bus*, sd_bus_message**);
    int (*sd_bus_get_unique_name)(sd_bus*, const char**);
    int (*sd_bus_add_fallback_vtable)(sd_bus*, sd_bus_slot**, const char*,
                                      const char*, const sd_bus_vtable*,
                                      sd_bus_object_find_t, void*);
    int (*sd_bus_call_method)(sd_bus*, const char*, const char*, const char*,
                              const char*, sd_bus_error*, sd_bus_message**,
                              const char*, ...);
    int (*sd_bus_message_new_method_return)(sd_bus_message*, sd_bus_message**);
    int (*sd_bus_message_append)(sd_bus_message*, const char*, ...);
    int (*sd_bus_message_read)(sd_bus_message*, const char*, ...);
    int (*sd_bus_message_new_signal)(sd_bus*, sd_bus_message**, const char*,
                                     const char*, const char*);
    int (*sd_bus_send)(sd_bus*, sd_bus_message*, uint64_t*);
    sd_bus_message* (*sd_bus_message_unref)(sd_bus_message*);
    void (*sd_bus_error_free)(sd_bus_error*);
    int (*sd_bus_message_open_container)(sd_bus_message*, char, const char*);
    int (*sd_bus_message_close_container)(sd_bus_message*);
} L;

static bool loadSdbus() {
    if (L.lib) return true;
    L.lib = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!L.lib) return false;
    void* l = L.lib;
#define RS(name) do { *reinterpret_cast<void**>(&L.name) = dlsym(l, #name); \
                      if (!L.name) { dlclose(l); L.lib = nullptr; return false; } } while (0)
    RS(sd_bus_new); RS(sd_bus_set_address); RS(sd_bus_set_bus_client);
    RS(sd_bus_start);
    RS(sd_bus_open_user); RS(sd_bus_unref); RS(sd_bus_flush);
    RS(sd_bus_process); RS(sd_bus_get_unique_name);
    RS(sd_bus_add_fallback_vtable); RS(sd_bus_call_method);
    RS(sd_bus_message_new_method_return); RS(sd_bus_message_append);
    RS(sd_bus_message_read); RS(sd_bus_message_new_signal);
    RS(sd_bus_send); RS(sd_bus_message_unref); RS(sd_bus_error_free);
    RS(sd_bus_message_open_container); RS(sd_bus_message_close_container);
#undef RS
    L.vtable_format_ref =
        (const unsigned*)dlsym(l, "sd_bus_object_vtable_format");
    if (!L.vtable_format_ref) { dlclose(l); L.lib = nullptr; return false; }
    return true;
}

// ---------------------------------------------------------------------------
// Rôles / états AT-SPI (valeurs vérifiées sur libatspi 2.44)
// ---------------------------------------------------------------------------
enum { R_APPLICATION = 75, R_PUSH_BUTTON = 43, R_CHECK_BOX = 7, R_SLIDER = 51,
       R_ENTRY = 79, R_LIST = 31, R_LIST_ITEM = 32, R_HEADING = 83,
       R_GROUPING = 99, R_PANEL = 39, R_LABEL = 29, R_STATIC = 116 };
enum { S_ACTIVE = 1, S_CHECKED = 4, S_EDITABLE = 7, S_ENABLED = 8,
       S_FOCUSABLE = 11, S_FOCUSED = 12, S_SELECTABLE = 22, S_SELECTED = 23,
       S_SENSITIVE = 24, S_SHOWING = 25, S_SINGLE_LINE = 26, S_VISIBLE = 30,
       S_OPAQUE = 18 };

static uint32_t roleOf(int kx_role) {
    switch (kx_role) {
    case 1: return R_PUSH_BUTTON;
    case 2: return R_CHECK_BOX;
    case 3: return R_SLIDER;
    case 4: return R_ENTRY;
    case 5: return R_LIST;
    case 6: return R_LIST_ITEM;
    case 7: return R_HEADING;
    case 8: return R_GROUPING;
    default: return R_GROUPING;
    }
}
static const char* roleName(int kx_role) {
    switch (kx_role) {
    case 1: return "push button";
    case 2: return "check box";
    case 3: return "slider";
    case 4: return "entry";
    case 5: return "list";
    case 6: return "list item";
    case 7: return "heading";
    default: return "grouping";
    }
}

// ---------------------------------------------------------------------------
// Modèle de nœuds
// ---------------------------------------------------------------------------
struct KxNode {
    void* ident = nullptr;
    void* parent_ident = nullptr;
    int role = 0;
    std::string label, hint;
    double x = 0, y = 0, w = 0, h = 0;
    int flags = 0;
    std::string path; // /org/a11y/atspi/accessible/node<i>
    int parent_idx = -2; // -2 = root, -1 = nœud, >=0 index
    std::vector<int> kids;
};

static std::mutex g_mtx;
static std::vector<KxNode> g_nodes;       // en cours de build
static std::vector<KxNode> g_committed;   // snapshot servi aux AT
static sd_bus* g_bus = nullptr;
static std::vector<sd_bus_slot*> g_slots;
static kx_a11y_action_cb g_cb = nullptr;
static void* g_cb_ctx = nullptr;
static std::string g_app_id;
static double g_scale = 1.0;
static bool g_registered = false;

static const char* ROOT_PATH = "/org/a11y/atspi/accessible/root";
static const char* PREFIX = "/org/a11y/atspi/accessible";
static const char* NULL_PATH = "/org/a11y/atspi/null";
static const char* REGISTRY = "org.a11y.atspi.Registry";

// userdata NULL  = la racine application ; sinon KxNode*
static KxNode* nodeFromPath(const char* path) {
    if (!path) return nullptr;
    if (!strcmp(path, ROOT_PATH)) return nullptr; // racine = nullptr userdata
    int idx = -1;
    if (sscanf(path, "/org/a11y/atspi/accessible/node%d", &idx) != 1)
        return (KxNode*)-1; // pas un objet à nous
    if (idx < 0 || idx >= (int)g_committed.size()) return (KxNode*)-1;
    return &g_committed[idx];
}

static int findAccessible(sd_bus*, const char* path, const char*, void*,
                          void** found, sd_bus_error*) {
    KxNode* n = nodeFromPath(path);
    if (n == (KxNode*)-1) return 0;
    *found = n; // nullptr = racine, valide
    return 1;
}
static int findAction(sd_bus*, const char* path, const char*, void*,
                      void** found, sd_bus_error*) {
    KxNode* n = nodeFromPath(path);
    if (n == (KxNode*)-1) return 0;
    // Action exposée seulement sur les rôles actionnables.
    if (n && n->role != 1 && n->role != 2 && n->role != 3 && n->role != 6)
        return 0;
    *found = n;
    return 1;
}
static int findApplication(sd_bus*, const char* path, const char*, void*,
                           void** found, sd_bus_error*) {
    if (!path || strcmp(path, ROOT_PATH)) return 0;
    *found = nullptr;
    return 1;
}

// ---------------------------------------------------------------------------
// Helpers marshalling
// ---------------------------------------------------------------------------
static int reply_str(sd_bus_message* m, const char* s) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "s", s);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static const char* appUname() {
    const char* u = nullptr;
    if (!g_bus || L.sd_bus_get_unique_name(g_bus, &u) < 0 || !u) return "";
    return u;
}
static int reply_ref(sd_bus_message* m, const char* bus, const char* path) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "(so)", bus, path);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int reply_int(sd_bus_message* m, int v) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "i", v);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int reply_uint(sd_bus_message* m, uint32_t v) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "u", v);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int reply_bool(sd_bus_message* m, int v) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "b", v);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int reply_i4(sd_bus_message* m, int a, int b, int c, int d) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "(iiii)", a, b, c, d);
    return L.sd_bus_send(nullptr, r, nullptr);
}

// ---------------------------------------------------------------------------
// Accessible — propriétés
// ---------------------------------------------------------------------------
static int prop_get_str(sd_bus*, const char* path, const char* iface,
                        const char* prop, sd_bus_message* reply,
                        void* userdata, sd_bus_error*) {
    (void)iface;
    KxNode* n = (KxNode*)userdata;
    const char* v = "";
    char buf[64];
    if (!strcmp(prop, "Name")) {
        v = n ? n->label.c_str() : "Klaxon Gallery";
    } else if (!strcmp(prop, "Description") || !strcmp(prop, "HelpText")) {
        v = n ? n->hint.c_str() : "";
    } else if (!strcmp(prop, "Locale")) {
        v = "en_US";
    } else if (!strcmp(prop, "AccessibleId")) {
        if (n) { snprintf(buf, sizeof buf, "kx-%p", n->ident); v = buf; }
    }
    return L.sd_bus_message_append(reply, "s", v);
}
static int prop_get_uint(sd_bus*, const char*, const char*, const char* prop,
                         sd_bus_message* reply, void* userdata, sd_bus_error*) {
    uint32_t v = 0;
    if (!strcmp(prop, "version")) v = 0;
    return L.sd_bus_message_append(reply, "u", v);
}
static int prop_get_parent(sd_bus*, const char* path, const char*, const char*,
                           sd_bus_message* reply, void* userdata,
                           sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    const char* uname = appUname();
    if (!n)
        return L.sd_bus_message_append(reply, "(so)", "", NULL_PATH);
    if (n->parent_idx == -2)
        return L.sd_bus_message_append(reply, "(so)", uname, ROOT_PATH);
    return L.sd_bus_message_append(reply, "(so)", uname,
                                   g_committed[n->parent_idx].path.c_str());
}
static int prop_get_childcount(sd_bus*, const char*, const char*, const char*,
                               sd_bus_message* reply, void* userdata,
                               sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    int c = 0;
    if (!n) { for (auto& k : g_committed) if (k.parent_idx == -2) c++; }
    else c = (int)n->kids.size();
    return L.sd_bus_message_append(reply, "i", c);
}

// ---------------------------------------------------------------------------
// Accessible — méthodes
// ---------------------------------------------------------------------------
static int m_GetChildAtIndex(sd_bus_message* m, void* userdata, sd_bus_error*) {
    int idx = 0;
    L.sd_bus_message_read(m, "i", &idx);
    KxNode* n = (KxNode*)userdata;
    int ci = -1;
    if (!n) {
        int seen = -1;
        for (size_t i = 0; i < g_committed.size(); i++)
            if (g_committed[i].parent_idx == -2 && ++seen == idx) { ci = (int)i; break; }
    } else if (idx >= 0 && idx < (int)n->kids.size()) {
        ci = n->kids[idx];
    }
    if (ci < 0) return reply_ref(m, "", NULL_PATH);
    return reply_ref(m, appUname(),
                     g_committed[ci].path.c_str());
}
static int m_GetChildren(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    const char* uname = appUname();
    // a(so) via open_container (containers refusés dans le format variadique)
    extern int append_children_array(sd_bus_message*, const char*, KxNode*);
    int rc = append_children_array(r, uname, n);
    if (rc < 0) { L.sd_bus_message_unref(r); return rc; }
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GetIndexInParent(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    int idx = -1;
    if (n) {
        int seen = -1;
        for (size_t i = 0; i < g_committed.size(); i++) {
            if (&g_committed[i] == n) { idx = seen >= 0 ? seen : -1; break; }
            if (g_committed[i].parent_idx == n->parent_idx) seen++;
        }
        // recalcule simple : compte les frères avant nous
        idx = 0;
        for (auto& k : g_committed) {
            if (&k == n) break;
            if (k.parent_idx == n->parent_idx) idx++;
        }
    }
    return reply_int(m, idx);
}
static int m_GetRole(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    return reply_uint(m, n ? roleOf(n->role) : R_APPLICATION);
}
static int m_GetRoleName(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    return reply_str(m, n ? roleName(n->role) : "application");
}
static int m_GetState(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    uint64_t st = (1ULL << S_ENABLED) | (1ULL << S_SENSITIVE) |
                  (1ULL << S_SHOWING) | (1ULL << S_VISIBLE) |
                  (1ULL << S_OPAQUE);
    if (!n) st |= (1ULL << S_ACTIVE);
    if (n) {
        if (n->flags & KX_A11Y_FOCUSABLE) st |= (1ULL << S_FOCUSABLE) | (1ULL << S_SELECTABLE);
        if (n->role == 6) st |= (1ULL << S_SELECTABLE); // list item toujours selectable
        if (n->flags & KX_A11Y_FOCUSED) st |= (1ULL << S_FOCUSED);
        if (n->flags & KX_A11Y_SELECTED) {
            st |= (1ULL << S_SELECTED);
            if (n->role == 2) st |= (1ULL << S_CHECKED); // checkbox seule
        }
        if (n->role == 4) st |= (1ULL << S_EDITABLE) | (1ULL << S_SINGLE_LINE);
    }
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    extern int append_state_array(sd_bus_message*, uint64_t);
    append_state_array(r, st);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GetAttributes(sd_bus_message* m, void*, sd_bus_error*) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "a{ss}", 0);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GetRelationSet(sd_bus_message* m, void*, sd_bus_error*) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "a(ua(so))", 0);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GetApplication(sd_bus_message* m, void*, sd_bus_error*) {
    return reply_ref(m, appUname(), ROOT_PATH);
}

// ---------------------------------------------------------------------------
// Component — bornes en coords fenêtre (limitation documentée : le shim ne
// connaît pas l'origine écran de la fenêtre ; v1 rend les coords fenêtre pour
// coord_type=screen aussi — suffit pour fullscreen / tests, à affiner quand
// le host passera la position fenêtre).
// ---------------------------------------------------------------------------
static int m_GetExtents(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    if (!n) return reply_i4(m, 0, 0, 0, 0);
    return reply_i4(m, (int)(n->x * g_scale), (int)(n->y * g_scale),
                    (int)(n->w * g_scale), (int)(n->h * g_scale));
}
static int m_GetPosition(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "ii", n ? (int)(n->x * g_scale) : 0,
                            n ? (int)(n->y * g_scale) : 0);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GetSize(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "ii", n ? (int)(n->w * g_scale) : 0,
                            n ? (int)(n->h * g_scale) : 0);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_Contains(sd_bus_message* m, void* userdata, sd_bus_error*) {
    int x = 0, y = 0; uint32_t ct = 0;
    L.sd_bus_message_read(m, "iiu", &x, &y, &ct);
    KxNode* n = (KxNode*)userdata;
    int hit = 0;
    if (n) {
        double sx = x / g_scale, sy = y / g_scale;
        hit = sx >= n->x && sy >= n->y && sx < n->x + n->w && sy < n->y + n->h;
    }
    return reply_bool(m, hit);
}
static int m_GetAccessibleAtPoint(sd_bus_message* m, void* userdata,
                                  sd_bus_error*) {
    int x = 0, y = 0; uint32_t ct = 0;
    L.sd_bus_message_read(m, "iiu", &x, &y, &ct);
    double sx = x / g_scale, sy = y / g_scale;
    // DFS = ordre de rendu → le dernier qui contient le point est au-dessus.
    int best = -1;
    for (size_t i = 0; i < g_committed.size(); i++) {
        auto& k = g_committed[i];
        if (sx >= k.x && sy >= k.y && sx < k.x + k.w && sy < k.y + k.h)
            best = (int)i;
    }
    if (best < 0) return reply_ref(m, "", NULL_PATH);
    return reply_ref(m, appUname(),
                     g_committed[best].path.c_str());
}
static int m_GetLayer(sd_bus_message* m, void*, sd_bus_error*) {
    return reply_uint(m, 3); // ATSPI_LAYER_WIDGET
}
static int m_GetMDIZOrder(sd_bus_message* m, void*, sd_bus_error*) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "n", (int16_t)-1);
    return L.sd_bus_send(nullptr, r, nullptr);
}
static int m_GrabFocus(sd_bus_message* m, void*, sd_bus_error*) {
    return reply_bool(m, 1);
}
static int m_GetAlpha(sd_bus_message* m, void*, sd_bus_error*) {
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    L.sd_bus_message_append(r, "d", 1.0);
    return L.sd_bus_send(nullptr, r, nullptr);
}

// ---------------------------------------------------------------------------
// Action
// ---------------------------------------------------------------------------
static int actionCount(KxNode* n) { return n && n->role == 3 ? 3 : 1; }
static const char* actionName(int i, int role) {
    if (role == 3) return i == 0 ? "press" : (i == 1 ? "increment" : "decrement");
    return "press";
}
static int prop_get_nactions(sd_bus*, const char*, const char*, const char*,
                             sd_bus_message* reply, void* userdata,
                             sd_bus_error*) {
    return L.sd_bus_message_append(reply, "i", actionCount((KxNode*)userdata));
}
static int m_DoAction(sd_bus_message* m, void* userdata, sd_bus_error*) {
    int idx = 0;
    L.sd_bus_message_read(m, "i", &idx);
    KxNode* n = (KxNode*)userdata;
    if (!n || !g_cb) return reply_bool(m, 0);
    int act = 0;
    if (n->role == 3 && idx == 1) act = 1;
    else if (n->role == 3 && idx == 2) act = 2;
    g_cb(g_cb_ctx, n->ident, act);
    return reply_bool(m, 1);
}
static int m_GetActionName(sd_bus_message* m, void* userdata, sd_bus_error*) {
    int idx = 0;
    L.sd_bus_message_read(m, "i", &idx);
    return reply_str(m, actionName(idx, ((KxNode*)userdata)->role));
}
static int m_GetActionDesc(sd_bus_message* m, void* userdata, sd_bus_error*) {
    int idx = 0;
    L.sd_bus_message_read(m, "i", &idx);
    return reply_str(m, actionName(idx, ((KxNode*)userdata)->role));
}
static int m_GetKeyBinding(sd_bus_message* m, void*, sd_bus_error*) {
    return reply_str(m, "");
}
static int m_GetActions(sd_bus_message* m, void* userdata, sd_bus_error*) {
    KxNode* n = (KxNode*)userdata;
    sd_bus_message* r;
    if (L.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    extern int append_actions(sd_bus_message*, int);
    append_actions(r, n ? n->role : 0);
    return L.sd_bus_send(nullptr, r, nullptr);
}

// ---------------------------------------------------------------------------
// Application (racine uniquement) — Id writable : le registry l'écrit
// après Embed (contrat Socket).
// ---------------------------------------------------------------------------
static int prop_get_toolkit(sd_bus*, const char*, const char*, const char* prop,
                            sd_bus_message* reply, void*, sd_bus_error*) {
    const char* v = "";
    if (!strcmp(prop, "ToolkitName") || !strcmp(prop, "Version")) v = "klaxon";
    else if (!strcmp(prop, "ToolkitVersion") || !strcmp(prop, "AtspiVersion")) v = "2.1";
    else if (!strcmp(prop, "Id")) v = g_app_id.c_str();
    return L.sd_bus_message_append(reply, "s", v);
}
static int prop_set_id(sd_bus*, const char*, const char*, const char*,
                       sd_bus_message* value, void*, sd_bus_error*) {
    const char* s = nullptr;
    if (L.sd_bus_message_read(value, "s", &s) < 0) return -1;
    g_app_id = s ? s : "";
    return 1;
}

// ---------------------------------------------------------------------------
// VTables
// ---------------------------------------------------------------------------
static sd_bus_vtable VT_ACCESSIBLE[] = {
    VT_START,
    VT_PROP("version", "u", prop_get_uint),
    VT_PROP("Name", "s", prop_get_str),
    VT_PROP("Description", "s", prop_get_str),
    VT_PROP("Locale", "s", prop_get_str),
    VT_PROP("AccessibleId", "s", prop_get_str),
    VT_PROP("HelpText", "s", prop_get_str),
    VT_PROP("Parent", "(so)", prop_get_parent),
    VT_PROP("ChildCount", "i", prop_get_childcount),
    VT_METHOD("GetChildAtIndex", "i", "(so)", m_GetChildAtIndex),
    VT_METHOD("GetChildren", "", "a(so)", m_GetChildren),
    VT_METHOD("GetIndexInParent", "", "i", m_GetIndexInParent),
    VT_METHOD("GetRole", "", "u", m_GetRole),
    VT_METHOD("GetRoleName", "", "s", m_GetRoleName),
    VT_METHOD("GetLocalizedRoleName", "", "s", m_GetRoleName),
    VT_METHOD("GetState", "", "au", m_GetState),
    VT_METHOD("GetAttributes", "", "a{ss}", m_GetAttributes),
    VT_METHOD("GetRelationSet", "", "a(ua(so))", m_GetRelationSet),
    VT_METHOD("GetApplication", "", "(so)", m_GetApplication),
    VT_END,
};
static sd_bus_vtable VT_COMPONENT[] = {
    VT_START,
    VT_METHOD("GetExtents", "u", "(iiii)", m_GetExtents),
    VT_METHOD("GetPosition", "u", "ii", m_GetPosition),
    VT_METHOD("GetSize", "", "ii", m_GetSize),
    VT_METHOD("Contains", "iiu", "b", m_Contains),
    VT_METHOD("GetAccessibleAtPoint", "iiu", "(so)", m_GetAccessibleAtPoint),
    VT_METHOD("GetLayer", "", "u", m_GetLayer),
    VT_METHOD("GetMDIZOrder", "", "n", m_GetMDIZOrder),
    VT_METHOD("GrabFocus", "", "b", m_GrabFocus),
    VT_METHOD("GetAlpha", "", "d", m_GetAlpha),
    VT_END,
};
static sd_bus_vtable VT_ACTION[] = {
    VT_START,
    VT_PROP("NActions", "i", prop_get_nactions),
    VT_METHOD("DoAction", "i", "b", m_DoAction),
    VT_METHOD("GetName", "i", "s", m_GetActionName),
    VT_METHOD("GetLocalizedName", "i", "s", m_GetActionName),
    VT_METHOD("GetDescription", "i", "s", m_GetActionDesc),
    VT_METHOD("GetKeyBinding", "i", "s", m_GetKeyBinding),
    VT_METHOD("GetActions", "", "a(sss)", m_GetActions),
    VT_END,
};
static sd_bus_vtable VT_APPLICATION[] = {
    VT_START,
    VT_PROP("ToolkitName", "s", prop_get_toolkit),
    VT_PROP("Version", "s", prop_get_toolkit),
    VT_PROP("ToolkitVersion", "s", prop_get_toolkit),
    VT_PROP("AtspiVersion", "s", prop_get_toolkit),
    VT_PROP_W("Id", "s", prop_get_toolkit, prop_set_id),
    VT_END,
};

// ---------------------------------------------------------------------------
// Helpers de marshalling complexes (containers)
// ---------------------------------------------------------------------------
int append_children_array(sd_bus_message* r, const char* uname, KxNode* n) {
    L.sd_bus_message_open_container(r, 'a', "(so)");
    if (!n) {
        for (auto& k : g_committed)
            if (k.parent_idx == -2) {
                L.sd_bus_message_open_container(r, 'r', "so");
                L.sd_bus_message_append(r, "so", uname, k.path.c_str());
                L.sd_bus_message_close_container(r);
            }
    } else {
        for (int ci : n->kids) {
            L.sd_bus_message_open_container(r, 'r', "so");
            L.sd_bus_message_append(r, "so", uname,
                                    g_committed[ci].path.c_str());
            L.sd_bus_message_close_container(r);
        }
    }
    L.sd_bus_message_close_container(r);
    return 0;
}
int append_state_array(sd_bus_message* r, uint64_t st) {
    L.sd_bus_message_open_container(r, 'a', "u");
    L.sd_bus_message_append(r, "u", (uint32_t)(st & 0xFFFFFFFF));
    L.sd_bus_message_append(r, "u", (uint32_t)(st >> 32));
    L.sd_bus_message_close_container(r);
    return 0;
}
int append_actions(sd_bus_message* r, int role) {
    int n = role == 3 ? 3 : 1;
    L.sd_bus_message_open_container(r, 'a', "(sss)");
    for (int i = 0; i < n; i++) {
        const char* nm = actionName(i, role);
        L.sd_bus_message_open_container(r, 'r', "sss");
        L.sd_bus_message_append(r, "sss", nm, nm, "");
        L.sd_bus_message_close_container(r);
    }
    L.sd_bus_message_close_container(r);
    return 0;
}

// ---------------------------------------------------------------------------
// Connexion + enregistrement
// ---------------------------------------------------------------------------
static void emitStateChanged(const char* path, const char* state, int en) {
    sd_bus_message* m = nullptr;
    if (!g_bus) return;
    if (L.sd_bus_message_new_signal(g_bus, &m, path,
                                  "org.a11y.atspi.Event.Object",
                                  "StateChanged") < 0)
        return;
    L.sd_bus_message_append(m, "siiva{sv}", state, en, 0, "s", "", 0);
    L.sd_bus_send(g_bus, m, nullptr);
    L.sd_bus_flush(g_bus);
}
static void emitChildrenChanged() {
    sd_bus_message* m = nullptr;
    if (!g_bus) return;
    if (L.sd_bus_message_new_signal(g_bus, &m, ROOT_PATH,
                                  "org.a11y.atspi.Event.Object",
                                  "ChildrenChanged") < 0)
        return;
    L.sd_bus_message_append(m, "siiva{sv}", "add", 0, 0, "s", "", 0);
    L.sd_bus_send(g_bus, m, nullptr);
    L.sd_bus_flush(g_bus);
}

static int a11yConnect() {
    if (g_bus) return 1;
    if (!loadSdbus()) return 0;
    const char* addr = getenv("AT_SPI_BUS_ADDRESS");
    if (L.sd_bus_new(&g_bus) < 0) return 0;
    if (addr && *addr) {
        if (L.sd_bus_set_address(g_bus, addr) < 0) { g_bus = nullptr; return 0; }
        // Sans set_bus_client, sd_bus_start ouvre la socket sans faire le
        // handshake Hello → le démon coupe (ECONNRESET, mesuré).
        L.sd_bus_set_bus_client(g_bus, 1);
        if (L.sd_bus_start(g_bus) < 0) { L.sd_bus_unref(g_bus); g_bus = nullptr; return 0; }
    } else {
        // Sans adresse explicite : bus de session (la session de bureau expose
        // le bus a11y via org.a11y.Bus.GetAddress — à résoudre si besoin).
        if (L.sd_bus_open_user(&g_bus) < 0) { g_bus = nullptr; return 0; }
    }
    // Injecte la référence de format dans chaque START entry (vtables
    // construites en statique — le pointeur n'est connu qu'après dlopen).
    VT_ACCESSIBLE[0].x.start.vtable_format_reference = L.vtable_format_ref;
    VT_COMPONENT[0].x.start.vtable_format_reference = L.vtable_format_ref;
    VT_ACTION[0].x.start.vtable_format_reference = L.vtable_format_ref;
    VT_APPLICATION[0].x.start.vtable_format_reference = L.vtable_format_ref;
    sd_bus_slot* sl;
    L.sd_bus_add_fallback_vtable(g_bus, &sl, PREFIX, "org.a11y.atspi.Accessible",
                                 VT_ACCESSIBLE, findAccessible, nullptr);
    if (sl) g_slots.push_back(sl);
    L.sd_bus_add_fallback_vtable(g_bus, &sl, PREFIX, "org.a11y.atspi.Component",
                                 VT_COMPONENT, findAccessible, nullptr);
    if (sl) g_slots.push_back(sl);
    L.sd_bus_add_fallback_vtable(g_bus, &sl, PREFIX, "org.a11y.atspi.Action",
                                 VT_ACTION, findAction, nullptr);
    if (sl) g_slots.push_back(sl);
    L.sd_bus_add_fallback_vtable(g_bus, &sl, ROOT_PATH,
                                 "org.a11y.atspi.Application",
                                 VT_APPLICATION, findApplication, nullptr);
    if (sl) g_slots.push_back(sl);
    return 1;
}

static int a11yRegister() {
    if (g_registered || !g_bus) return 1;
    sd_bus_error err = {0};
    sd_bus_message* rep = nullptr;
    const char* uname = nullptr;
    if (L.sd_bus_get_unique_name(g_bus, &uname) < 0 || !uname)
        uname = "";
    int rc = L.sd_bus_call_method(g_bus, REGISTRY, ROOT_PATH,
                                  "org.a11y.atspi.Socket", "Embed",
                                  &err, &rep, "(so)", uname, ROOT_PATH);
    if (rc < 0) {
        fprintf(stderr, "kx_a11y: Embed failed: %s\n",
                err.message ? err.message : "?");
        L.sd_bus_error_free(&err);
        return -1;
    }
    if (rep) L.sd_bus_message_unref(rep);
    g_registered = true;
    return 0;
}

extern "C" {

int kx_a11y_sync_begin(void* /*unused*/, double scale) {
    if (!a11yConnect()) return 0;
    a11yRegister();
    std::lock_guard<std::mutex> lk(g_mtx);
    g_nodes.clear();
    g_scale = scale > 0 ? scale : 1.0;
    return 0;
}

int kx_a11y_sync_item(void* /*view*/, void* ident, void* parent_ident,
                      int role, const char* label, const char* hint,
                      double x, double y, double w, double h,
                      unsigned int flags) {
    std::lock_guard<std::mutex> lk(g_mtx);
    KxNode n;
    n.ident = ident;
    n.parent_ident = parent_ident;
    n.role = role;
    n.label = label ? label : "";
    n.hint = hint ? hint : "";
    n.x = x; n.y = y; n.w = w; n.h = h;
    n.flags = flags;
    char p[96];
    snprintf(p, sizeof p, "%s/node%d", PREFIX, (int)g_nodes.size());
    n.path = p;
    if (parent_ident == nullptr) n.parent_idx = -2;
    else {
        n.parent_idx = -1; // orphelin logique (ne devrait pas arriver)
        for (size_t i = 0; i < g_nodes.size(); i++)
            if (g_nodes[i].ident == parent_ident) { n.parent_idx = (int)i; break; }
    }
    if (n.parent_idx >= 0) g_nodes[n.parent_idx].kids.push_back((int)g_nodes.size());
    g_nodes.push_back(std::move(n));
    return 0;
}

int kx_a11y_sync_end(void* /*view*/) {
    std::lock_guard<std::mutex> lk(g_mtx);
    // diff grossier : taille ou contenu changé
    bool mut = g_nodes.size() != g_committed.size();
    if (!mut) {
        for (size_t i = 0; i < g_nodes.size(); i++)
            if (g_nodes[i].ident != g_committed[i].ident ||
                g_nodes[i].label != g_committed[i].label ||
                g_nodes[i].flags != g_committed[i].flags ||
                g_nodes[i].x != g_committed[i].x ||
                g_nodes[i].y != g_committed[i].y ||
                g_nodes[i].w != g_committed[i].w ||
                g_nodes[i].h != g_committed[i].h) { mut = true; break; }
    }
    // focus : notifie le changement avant de swapper
    if (mut) {
        for (auto& n : g_nodes)
            if (n.flags & KX_A11Y_FOCUSED) {
                bool was = false;
                for (auto& o : g_committed)
                    if (o.ident == n.ident) { was = o.flags & KX_A11Y_FOCUSED; break; }
                if (!was) emitStateChanged(n.path.c_str(), "focused", 1);
            }
    }
    g_committed = std::move(g_nodes);
    if (mut) emitChildrenChanged();
    return mut ? 1 : 0;
}

void kx_a11y_clear(void* /*view*/) {
    std::lock_guard<std::mutex> lk(g_mtx);
    g_nodes.clear();
    g_committed.clear();
    emitChildrenChanged();
}

void kx_a11y_set_action_handler(void* /*view*/, kx_a11y_action_cb cb,
                                void* ctx) {
    g_cb = cb; g_cb_ctx = ctx;
}

void kx_a11y_debug_dump(void* /*view*/) {
    std::lock_guard<std::mutex> lk(g_mtx);
    fprintf(stderr, "kx_a11y linux: %zu nodes\n", g_committed.size());
    for (auto& n : g_committed)
        fprintf(stderr, "  %s role=%d \"%s\" %.0f,%.0f %.0fx%.0f\n",
                n.path.c_str(), n.role, n.label.c_str(), n.x, n.y, n.w, n.h);
}

int kx_a11y_activate_ident(void* /*view*/, void* ident) {
    if (!g_cb || !ident) return -1;
    g_cb(g_cb_ctx, ident, 0);
    return 0;
}

/// Appelé à chaque tick host : draine les requêtes D-Bus (non bloquant).
int kx_a11y_pump() {
    if (!g_bus) return 0;
    int n = 0;
    while (L.sd_bus_process(g_bus, nullptr) > 0) n++;
    L.sd_bus_flush(g_bus);
    return n;
}

} // extern "C"
