// kx_a11y_win.cpp — pont a11y Windows (UI Automation) pour Klaxon.
//
// Contrat commun (A11Y-BRIDGES.md) :
//   kx_a11y_sync_begin(view=HWND, scale)
//   N × kx_a11y_sync_item(view, ident, parent_ident, role, label, hint,
//                          x, y, w, h, flags)   — strings UTF-8 copiées
//   kx_a11y_sync_end(view) → 1 si l'arbre a muté
//
//   role : 0 generic, 1 button, 2 checkbox, 3 slider, 4 textfield,
//          5 list, 6 listitem, 7 heading, 8 group
//   flags : 1 DISABLED | 2 FOCUSABLE | 4 FOCUSED | 8 SELECTED
//   bounds : px physiques client-window, top-left (pas de flip).
//
// Design : rebuild-with-reuse keyed by `ident` (node* zig — clé, jamais
// déréférencée). Chaque nœud = un provider COM qui possède sa copie des
// propriétés ; liens parent/enfant = strong refs. Les providers vus dans
// une génération gardent leur objet (runtime id stable) ; les non-vus sont
// détachés de l'arbre (le client peut encore détenir une réf — GetPropertyValue
// renvoie alors les dernières valeurs connues).
//
// WM_GETOBJECT : la fenêtre SDL a son propre WndProc — sous-classement par
// SetWindowLongPtr(GWLP_WNDPROC) installé au premier sync_begin (SDL ne
// consomme pas WM_GETOBJECT ; tout autre message est passé au WndProc SDL).
//
// Actions (v2) : kx_a11y_set_action_handler(hwnd, cb, ctx) enregistre le
// callback zig (a11yActionTrampoline) ; Invoke()/Select() → cb(ctx,ident,0),
// RangeValue.SetValue → cb(ctx,ident, 1|2) selon le signe du delta. Le cb
// rejoue le vrai input path côté zig (tap au centre / touches flèches).
// Le cb est appelé SANS g_mtx tenu (réentrance zig possible).
//
// Limites v2 (honnêtes) : SetFocus reste no-op (le focus zig suit l'action
// rejouée, pas l'ordre AT) ; Scroll/Value/Text patterns non exposés ;
// RangeValue expose min 0 max 100 small 1 large 10 avec état interne —
// la valeur réelle du slider vit côté zig.

#include <windows.h>
#include <UIAutomation.h>
#include <UIAutomationCore.h>
#include <oleauto.h>
#include <unordered_map>
#include <vector>
#include <string>
#include <mutex>

#include "kx_skia.h"   // kx_a11y_action_cb

namespace kxa11y {

static std::mutex g_mtx;

// Handler d'action global : enregistré avec view=nullptr (pattern Android)
// ou appliqué à tous les bridges futurs. Un handler par bridge prime.
static kx_a11y_action_cb g_default_cb = nullptr;
static void* g_default_ctx = nullptr;

static std::wstring u8w(const char* s) {
    if (!s || !*s) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 1) return L"";
    std::wstring w(n - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

static long roleControlType(int role) {
    switch (role) {
        case 1: return UIA_ButtonControlTypeId;
        case 2: return UIA_CheckBoxControlTypeId;
        case 3: return UIA_SliderControlTypeId;
        case 4: return UIA_EditControlTypeId;
        case 5: return UIA_ListControlTypeId;
        case 6: return UIA_ListItemControlTypeId;
        case 7: // heading → Group + LocalizedControlType "heading"
        case 8: return UIA_GroupControlTypeId;
        default: return UIA_GroupControlTypeId;
    }
}

class KxProvider;
struct KxNode {
    void* ident = nullptr;
    int role = 0, flags = 0;
    std::wstring label, hint;
    float x = 0, y = 0, w = 0, h = 0;   // client px
    KxProvider* parent = nullptr;        // strong ref
    std::vector<KxProvider*> children;   // strong refs
    int rid = 0;
    bool alive = true;
    double range_value = 0.0;            // état RangeValue (role 3)
};

struct KxBridge {
    HWND hwnd = nullptr;
    WNDPROC old_proc = nullptr;
    int generation = 0;
    std::unordered_map<void*, KxProvider*> by_ident;
    std::vector<KxProvider*> seen;
    KxProvider* root = nullptr;          // racine synthétique (le HWND)
    void* last_focus_ident = nullptr;
    int rid_counter = 1;
    bool structural_mut = false;
    bool props_mut = false;
    kx_a11y_action_cb action_cb = nullptr;
    void* action_ctx = nullptr;
};
static std::unordered_map<HWND, KxBridge*> g_bridges;
static int dbgOn() { static int v = -1; if (v < 0) v = getenv("KX_A11Y_DEBUG") ? 1 : 0; return v; }
#define DBG(...) do { if (dbgOn()) { fprintf(stderr, "[a11y] " __VA_ARGS__); fflush(stderr); } } while (0)

// Roles activables via InvokePattern : button(1), checkbox(2), listitem(6).
static bool invokeRole(int role) {
    return role == 1 || role == 2 || role == 6;
}

class KxProvider final : public IRawElementProviderSimple,
                         public IRawElementProviderFragment,
                         public IRawElementProviderFragmentRoot,
                         public ISelectionItemProvider,
                         public IInvokeProvider,
                         public IRangeValueProvider {
public:
    KxProvider(KxBridge* b, KxNode* n, bool is_root)
        : b_(b), n_(n), is_root_(is_root), ref_(1) {}

    // --- IUnknown ---------------------------------------------------------
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == IID_IUnknown || riid == IID_IRawElementProviderSimple)
            *ppv = static_cast<IRawElementProviderSimple*>(this);
        else if (riid == IID_IRawElementProviderFragment)
            *ppv = static_cast<IRawElementProviderFragment*>(this);
        else if (riid == IID_IRawElementProviderFragmentRoot)
            *ppv = static_cast<IRawElementProviderFragmentRoot*>(this);
        else if (riid == IID_ISelectionItemProvider && n_ && n_->role == 6)
            *ppv = static_cast<ISelectionItemProvider*>(this);
        else if (riid == IID_IInvokeProvider && n_ && invokeRole(n_->role))
            *ppv = static_cast<IInvokeProvider*>(this);
        else if (riid == IID_IRangeValueProvider && n_ && n_->role == 3)
            *ppv = static_cast<IRangeValueProvider*>(this);
        else {
            wchar_t iid[64]; StringFromGUID2(riid, iid, 64);
            DBG("QI miss root=%d iid=%ls\n", (int)is_root_, iid);
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&ref_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG n = InterlockedDecrement(&ref_);
        if (n == 0) delete this;
        return n;
    }

    // --- IRawElementProviderSimple ----------------------------------------
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* pRet) override {
        DBG("get_ProviderOptions root=%d\n", (int)is_root_);
        *pRet = (ProviderOptions)ProviderOptions_ServerSideProvider;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown** pRet) override {
        *pRet = nullptr;
        if (id == UIA_SelectionItemPatternId && n_ && n_->role == 6)
            QueryInterface(IID_ISelectionItemProvider, (void**)pRet);
        else if (id == UIA_InvokePatternId && n_ && invokeRole(n_->role))
            QueryInterface(IID_IInvokeProvider, (void**)pRet);
        else if (id == UIA_RangeValuePatternId && n_ && n_->role == 3)
            QueryInterface(IID_IRangeValueProvider, (void**)pRet);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id, VARIANT* pRet) override {
        VariantInit(pRet);
        DBG("GetPropertyValue id=%d root=%d\n", (int)id, (int)is_root_);
        std::lock_guard<std::mutex> lk(g_mtx);
        switch (id) {
        case UIA_NamePropertyId:
            if (is_root_) {
                pRet->vt = VT_BSTR;
                pRet->bstrVal = SysAllocString(L"Klaxon Gallery");
                return S_OK;
            }
            if (!n_) break;
            pRet->vt = VT_BSTR;
            pRet->bstrVal = SysAllocString(n_->label.c_str());
            return S_OK;
        case UIA_ControlTypePropertyId:
            pRet->vt = VT_I4;
            pRet->lVal = is_root_ ? UIA_PaneControlTypeId : roleControlType(n_->role);
            return S_OK;
        case UIA_LocalizedControlTypePropertyId:
            if (n_ && n_->role == 7) {
                pRet->vt = VT_BSTR;
                pRet->bstrVal = SysAllocString(L"heading");
                return S_OK;
            }
            break;
        case UIA_HelpTextPropertyId:
            if (n_ && !n_->hint.empty()) {
                pRet->vt = VT_BSTR;
                pRet->bstrVal = SysAllocString(n_->hint.c_str());
                return S_OK;
            }
            break;
        case UIA_BoundingRectanglePropertyId: {
            if (is_root_) {
                RECT rc; GetClientRect(b_->hwnd, &rc);
                MapWindowPoints(b_->hwnd, nullptr, (POINT*)&rc, 2);
                return boundsVariant(pRet, (float)rc.left, (float)rc.top,
                                     (float)(rc.right - rc.left),
                                     (float)(rc.bottom - rc.top));
            }
            if (!n_) break;
            POINT pt = { (LONG)n_->x, (LONG)n_->y };
            ClientToScreen(b_->hwnd, &pt);
            return boundsVariant(pRet, (float)pt.x, (float)pt.y, n_->w, n_->h);
        }
        case UIA_IsEnabledPropertyId:
            pRet->vt = VT_BOOL;
            pRet->boolVal = (n_ && (n_->flags & 1)) ? VARIANT_FALSE : VARIANT_TRUE;
            return S_OK;
        case UIA_IsKeyboardFocusablePropertyId:
            pRet->vt = VT_BOOL;
            pRet->boolVal = (is_root_ || (n_ && (n_->flags & 2))) ? VARIANT_TRUE : VARIANT_FALSE;
            return S_OK;
        case UIA_HasKeyboardFocusPropertyId:
            pRet->vt = VT_BOOL;
            pRet->boolVal = (n_ && (n_->flags & 4)) ? VARIANT_TRUE : VARIANT_FALSE;
            return S_OK;
        case UIA_IsControlElementPropertyId:
        case UIA_IsContentElementPropertyId:
        case UIA_IsSelectionItemPatternAvailablePropertyId:
            pRet->vt = VT_BOOL;
            pRet->boolVal = (id == UIA_IsSelectionItemPatternAvailablePropertyId)
                ? ((n_ && n_->role == 6) ? VARIANT_TRUE : VARIANT_FALSE)
                : VARIANT_TRUE;
            return S_OK;
        case UIA_AutomationIdPropertyId: {
            pRet->vt = VT_BSTR;
            wchar_t buf[32];
            swprintf(buf, 32, L"kx-%d", is_root_ ? 0 : n_->rid);
            pRet->bstrVal = SysAllocString(buf);
            return S_OK;
        }
        case UIA_NativeWindowHandlePropertyId:
            // HWND hôte : fragment root SEULEMENT. Sur un nœud enfant,
            // get_hwnd_from_provider s'en sert pour fusionner les providers
            // HWND/NonClient dans le nœud → ses "enfants" deviennent la
            // title bar + l'arbre complet (cycle infini parent/enfant).
            if (!is_root_) break;
            pRet->vt = VT_I4;
            pRet->lVal = (LONG)(intptr_t)b_->hwnd;
            return S_OK;
        case UIA_RuntimeIdPropertyId: {
            SAFEARRAY* sa = SafeArrayCreateVector(VT_I4, 0, 2);
            int* v; SafeArrayAccessData(sa, (void**)&v);
            v[0] = UiaAppendRuntimeId;
            v[1] = is_root_ ? 0 : (n_ ? n_->rid : 0);
            SafeArrayUnaccessData(sa);
            pRet->vt = VT_I4 | VT_ARRAY;
            pRet->parray = sa;
            return S_OK;
        }
        default: break;
        }
        pRet->vt = VT_EMPTY;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
        IRawElementProviderSimple** pRet) override {
        DBG("get_HostRawElementProvider root=%d\n", (int)is_root_);
        // Seul le fragment root expose le HWND hôte : si chaque nœud le
        // renvoyait, la couche de merge réinjecterait les providers
        // HWND/NonClient dans CHAQUE nœud (title bar comme enfant de nos
        // items → cycle infini parent/enfant).
        *pRet = nullptr;
        if (is_root_)
            return UiaHostProviderFromHwnd(b_->hwnd, pRet);
        return S_OK;
    }

    // --- IRawElementProviderFragment ---------------------------------------
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection dir,
                                       IRawElementProviderFragment** pRet) override {
        *pRet = nullptr;
        DBG("Navigate dir=%d root=%d n=%p\n", (int)dir, (int)is_root_, (void*)n_);
        std::lock_guard<std::mutex> lk(g_mtx);
        KxProvider* target = nullptr;
        switch (dir) {
        case NavigateDirection_Parent:
            // Une racine de fragment n'a PAS de parent : la navigation entre
            // racines est du ressort du provider fenêtre par défaut.
            target = is_root_ ? nullptr : n_->parent;
            break;
        case NavigateDirection_FirstChild:
            if (is_root_) {
                if (!b_->root->childrenOf().empty())
                    target = b_->root->childrenOf()[0];
            } else if (n_ && !n_->children.empty())
                target = n_->children[0];
            break;
        case NavigateDirection_LastChild:
            if (is_root_) {
                auto& c = b_->root->childrenOf();
                if (!c.empty()) target = c.back();
            } else if (n_ && !n_->children.empty())
                target = n_->children.back();
            break;
        case NavigateDirection_NextSibling:
        case NavigateDirection_PreviousSibling: {
            if (is_root_ || !n_ || !n_->parent) break;
            KxNode* pn = n_->parent->node();
            if (!pn) break;
            auto& sibs = pn->children;
            for (size_t i = 0; i < sibs.size(); ++i) {
                if (sibs[i] == this) {
                    if (dir == NavigateDirection_NextSibling && i + 1 < sibs.size())
                        target = sibs[i + 1];
                    if (dir == NavigateDirection_PreviousSibling && i > 0)
                        target = sibs[i - 1];
                    break;
                }
            }
            break;
        }
        }
        if (target) *pRet = fragmentOf(target);
        if (dbgOn()) {
            KxNode* tn = target ? target->node() : nullptr;
            DBG("Navigate -> target=%p rid=%d name=%.40ls\n", (void*)target,
                tn ? tn->rid : -1,
                tn ? tn->label.c_str() : (const wchar_t*)L"-");
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** pRet) override {
        DBG("GetRuntimeId root=%d rid=%d\n", (int)is_root_, n_ ? n_->rid : -1);
        std::lock_guard<std::mutex> lk(g_mtx);
        SAFEARRAY* sa = SafeArrayCreateVector(VT_I4, 0, 2);
        int* v; SafeArrayAccessData(sa, (void**)&v);
        v[0] = UiaAppendRuntimeId;
        v[1] = is_root_ ? 0 : n_->rid;
        SafeArrayUnaccessData(sa);
        *pRet = sa;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* pRet) override {
        std::lock_guard<std::mutex> lk(g_mtx);
        if (is_root_) {
            RECT rc; GetClientRect(b_->hwnd, &rc);
            MapWindowPoints(b_->hwnd, nullptr, (POINT*)&rc, 2);
            pRet->left = rc.left; pRet->top = rc.top;
            pRet->width = rc.right - rc.left; pRet->height = rc.bottom - rc.top;
            return S_OK;
        }
        if (!n_) return E_FAIL;
        POINT pt = { (LONG)n_->x, (LONG)n_->y };
        ClientToScreen(b_->hwnd, &pt);
        pRet->left = pt.x; pRet->top = pt.y;
        pRet->width = n_->w; pRet->height = n_->h;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** pRet) override {
        *pRet = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override {
        // Limitation v1 : ne remonte pas au focus zig — S_OK no-op.
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(
        IRawElementProviderFragmentRoot** pRet) override {
        *pRet = nullptr;
        DBG("get_FragmentRoot root=%d n=%p\n", (int)is_root_, (void*)n_);
        std::lock_guard<std::mutex> lk(g_mtx);
        if (b_->root) {
            b_->root->AddRef();
            *pRet = static_cast<IRawElementProviderFragmentRoot*>(b_->root);
        }
        return S_OK;
    }

    // --- IRawElementProviderFragmentRoot (racine seule) ---------------------
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(
        double x, double y, IRawElementProviderFragment** pRet) override {
        *pRet = nullptr;
        std::lock_guard<std::mutex> lk(g_mtx);
        POINT pt = { (LONG)x, (LONG)y };
        ScreenToClient(b_->hwnd, &pt);
        KxProvider* best = b_->root ? hitDeepest(b_->root, (float)pt.x, (float)pt.y)
                                  : nullptr;
        if (best && best != b_->root) *pRet = fragmentOf(best);
        else if (b_->root) { b_->root->AddRef(); *pRet = b_->root; }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(
        IRawElementProviderFragment** pRet) override {
        *pRet = nullptr;
        std::lock_guard<std::mutex> lk(g_mtx);
        for (auto& kv : b_->by_ident) {
            KxProvider* p = kv.second;
            if (p->node() && (p->node()->flags & 4)) { *pRet = fragmentOf(p); break; }
        }
        return S_OK;
    }

    // --- ISelectionItemProvider (role==6 seulement) -------------------------
    HRESULT STDMETHODCALLTYPE Select() override {
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!n_) return UIA_E_INVALIDOPERATION;
        }
        // Action 0 = activation : le cb zig rejoue un vrai tap au centre du
        // node (pointer_down/up à ses coords). Fallback v1 : clic synthétique
        // WM_LBUTTON posté si aucun handler n'est enregistré.
        if (dispatchAction(this, 0)) return S_OK;
        std::lock_guard<std::mutex> lk(g_mtx);
        if (!n_) return UIA_E_INVALIDOPERATION;
        int cx = (int)(n_->x + n_->w / 2), cy = (int)(n_->y + n_->h / 2);
        PostMessage(b_->hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(cx, cy));
        PostMessage(b_->hwnd, WM_LBUTTONUP, 0, MAKELPARAM(cx, cy));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return Select(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override {
        return UIA_E_INVALIDOPERATION;   // mono-sélection gallery
    }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL* pRet) override {
        std::lock_guard<std::mutex> lk(g_mtx);
        *pRet = (n_ && (n_->flags & 8)) ? TRUE : FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(
        IRawElementProviderSimple** pRet) override {
        *pRet = nullptr;
        std::lock_guard<std::mutex> lk(g_mtx);
        if (n_ && n_->parent) {
            n_->parent->AddRef();
            *pRet = static_cast<IRawElementProviderSimple*>(n_->parent);
        }
        return S_OK;
    }

    // --- IInvokeProvider (roles 1/2/6) --------------------------------------
    HRESULT STDMETHODCALLTYPE Invoke() override {
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!n_) return UIA_E_INVALIDOPERATION;
        }
        return dispatchAction(this, 0) ? S_OK : UIA_E_INVALIDOPERATION;
    }

    // --- IRangeValueProvider (role==3) --------------------------------------
    HRESULT STDMETHODCALLTYPE SetValue(double val) override {
        int action;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!n_) return UIA_E_INVALIDOPERATION;
            action = (val >= n_->range_value) ? 1 : 2;
            n_->range_value = val;
        }
        return dispatchAction(this, action) ? S_OK : UIA_E_INVALIDOPERATION;
    }
    HRESULT STDMETHODCALLTYPE get_Value(double* pRet) override {
        std::lock_guard<std::mutex> lk(g_mtx);
        *pRet = n_ ? n_->range_value : 0.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* pRet) override {
        *pRet = FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Maximum(double* pRet) override {
        *pRet = 100.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Minimum(double* pRet) override {
        *pRet = 0.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double* pRet) override {
        *pRet = 10.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double* pRet) override {
        *pRet = 1.0;
        return S_OK;
    }

    // --- internes -----------------------------------------------------------
    // dispatchAction : invoke le handler d'action hors lock (ident = node*).
    // Retourne 1 si un handler était enregistré (action dispatchée).
    static int dispatchAction(KxProvider* p, int action) {
        kx_a11y_action_cb cb;
        void* ctx;
        void* ident;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!p->n_) return 0;
            ident = p->n_->ident;
            cb = p->b_->action_cb ? p->b_->action_cb : g_default_cb;
            ctx = p->b_->action_cb ? p->b_->action_ctx : g_default_ctx;
        }
        if (!cb || !ident) return 0;
        cb(ctx, ident, action);
        return 1;
    }

    KxNode* node() { return n_; }
    KxBridge* bridge() { return b_; }
    std::vector<KxProvider*>& childrenOf() { return n_ ? n_->children : empty_; }
    void setNode(KxNode* n) { n_ = n; }

private:
    static std::vector<KxProvider*> empty_;
    static IRawElementProviderFragment* fragmentOf(KxProvider* p) {
        IRawElementProviderFragment* f = nullptr;
        p->QueryInterface(IID_IRawElementProviderFragment, (void**)&f);
        return f;
    }
    static HRESULT boundsVariant(VARIANT* pRet, float x, float y, float w, float h) {
        SAFEARRAY* sa = SafeArrayCreateVector(VT_R8, 0, 4);
        double* v; SafeArrayAccessData(sa, (void**)&v);
        v[0] = x; v[1] = y; v[2] = w; v[3] = h;
        SafeArrayUnaccessData(sa);
        pRet->vt = VT_R8 | VT_ARRAY;
        pRet->parray = sa;
        return S_OK;
    }
    // Plus profond contenant le point ; enfants en ordre inverse (z-order :
    // dessinés tard = au-dessus).
    static KxProvider* hitDeepest(KxProvider* p, float px, float py) {
        KxNode* n = p->node();
        if (n) {
            for (auto it = n->children.rbegin(); it != n->children.rend(); ++it) {
                KxProvider* c = *it;
                KxNode* cn = c->node();
                if (!cn) continue;
                if (px >= cn->x && px < cn->x + cn->w &&
                    py >= cn->y && py < cn->y + cn->h) {
                    KxProvider* d = hitDeepest(c, px, py);
                    return d ? d : c;
                }
            }
        }
        return p;
    }

    KxBridge* b_;
    KxNode* n_;
    bool is_root_;
    ULONG ref_;
};
std::vector<KxProvider*> KxProvider::empty_;

// ---------------------------------------------------------------------------
// Subclass HWND — intercepte WM_GETOBJECT avant le WndProc SDL.
// ---------------------------------------------------------------------------
static LRESULT CALLBACK KxUiaWndProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    KxBridge* b = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_bridges.find(hwnd);
        if (it != g_bridges.end()) b = it->second;
    }
    if (msg == WM_GETOBJECT && b &&
        (DWORD)l == (DWORD)UiaRootObjectId) {
        IRawElementProviderSimple* root;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            if (!b->root) {
                auto* rn = new KxNode();
                rn->rid = b->rid_counter++;
                b->root = new KxProvider(b, rn, true);
            }
            root = b->root;
        }
        DBG("WM_GETOBJECT hwnd=%p root=%p tid=%ld\n", hwnd, (void*)root,
            (long)GetCurrentThreadId());
        // Le mutex est RELÂCHÉ avant l'appel : UiaReturnRawElementProvider
        // rentre dans nos méthodes (Navigate/GetPropertyValue…), qui reprennent
        // g_mtx — un mutex non récursif tenu ici = self-deadlock du wrap.
        return UiaReturnRawElementProvider(hwnd, w, l, root);
    }
    if (b && b->old_proc)
        return CallWindowProc(b->old_proc, hwnd, msg, w, l);
    return DefWindowProc(hwnd, msg, w, l);
}

static KxBridge* bridgeFor(HWND hwnd) {
    auto it = g_bridges.find(hwnd);
    if (it != g_bridges.end()) return it->second;
    // UIA marshals le provider via son thread provider + GIT quand
    // UseComThreading est posé : il faut COM initialisé dans notre processus.
    // Idempotent par thread (S_FALSE si déjà fait, RPC_E_CHANGED_MODE si STA).
    APTTYPE at = APTTYPE_CURRENT; APTTYPEQUALIFIER aq = APTTYPEQUALIFIER_NONE;
    HRESULT ha = CoGetApartmentType(&at, &aq);
    DBG("apartment hr=%08lx type=%d qual=%d tid=%ld\n", (unsigned long)ha,
        (int)at, (int)aq, (long)GetCurrentThreadId());
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DBG("CoInitializeEx hr=%08lx\n", (unsigned long)hr);
    auto* b = new KxBridge();
    b->hwnd = hwnd;
    b->action_cb = g_default_cb;
    b->action_ctx = g_default_ctx;
    g_bridges[hwnd] = b;
    // Sous-classement : on garde le WndProc SDL pour tout le reste.
    b->old_proc = (WNDPROC)SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                                           (LONG_PTR)KxUiaWndProc);
    DBG("subclass hwnd=%p old=%p\n", hwnd, (void*)b->old_proc);
    return b;
}

// Détruit les nœuds/providers non vus de la génération précédente.
static void pruneUnseen(KxBridge* b) {
    for (auto it = b->by_ident.begin(); it != b->by_ident.end();) {
        KxProvider* p = it->second;
        bool seen = false;
        for (KxProvider* s : b->seen) if (s == p) { seen = true; break; }
        if (!seen) {
            KxNode* n = p->node();
            if (n) {
                if (n->parent) n->parent->Release(), n->parent = nullptr;
                for (KxProvider* c : n->children) c->Release();
                n->children.clear();
                n->alive = false;
            }
            p->Release();          // relâche la ref du map
            it = b->by_ident.erase(it);
            b->structural_mut = true;
        } else ++it;
    }
}

} // namespace kxa11y

using namespace kxa11y;

extern "C" {

int kx_a11y_sync_begin(void* view, double scale) {
    (void)scale;  // bounds déjà en px physiques — scale informatif
    HWND hwnd = (HWND)view;
    if (!hwnd) return 0;
    std::lock_guard<std::mutex> lk(g_mtx);
    KxBridge* b = bridgeFor(hwnd);
    b->generation++;
    b->seen.clear();
    b->structural_mut = false;
    b->props_mut = false;
    return 0;
}

int kx_a11y_sync_item(void* view, void* ident, void* parent_ident,
                      int role, const char* label, const char* hint,
                      double x, double y, double w, double h, unsigned flags) {
    HWND hwnd = (HWND)view;
    if (!hwnd || !ident) return -1;
    std::lock_guard<std::mutex> lk(g_mtx);
    KxBridge* b = bridgeFor(hwnd);

    KxProvider* p = nullptr;
    auto it = b->by_ident.find(const_cast<void*>(ident));
    if (it != b->by_ident.end()) {
        p = it->second;
    } else {
        auto* n = new KxNode();
        n->ident = const_cast<void*>(ident);
        n->rid = b->rid_counter++;
        p = new KxProvider(b, n, false);
        p->AddRef();                       // ref du map
        b->by_ident[n->ident] = p;
        b->structural_mut = true;
    }
    KxNode* n = p->node();

    // props update (détection de mutation conservatrice)
    std::wstring nl = u8w(label), nh = u8w(hint);
    if (nl != n->label || nh != n->hint || n->role != role ||
        n->flags != flags || n->x != (float)x || n->y != (float)y ||
        n->w != (float)w || n->h != (float)h)
        b->props_mut = true;
    n->label = nl; n->hint = nh;
    n->role = role; n->flags = flags;
    n->x = (float)x; n->y = (float)y; n->w = (float)w; n->h = (float)h;

    // (re)parenting : DFS garantit que le parent a été vu avant l'enfant.
    KxProvider* par = b->root;
    if (parent_ident) {
        auto pit = b->by_ident.find(const_cast<void*>(parent_ident));
        if (pit != b->by_ident.end()) par = pit->second;
    }
    if (!par) {   // sécurité : racine synthétique si absente
        auto* rn = new KxNode();
        rn->rid = b->rid_counter++;
        b->root = new KxProvider(b, rn, true);
        par = b->root;
    }
    if (n->parent != par) {
        if (n->parent) {
            // détache de l'ancien parent
            auto& sibs = n->parent->node()->children;
            for (auto sit = sibs.begin(); sit != sibs.end(); ++sit)
                if (*sit == p) { sibs.erase(sit); break; }
            n->parent->Release();
            b->structural_mut = true;
        }
        n->parent = par;
        par->AddRef();
        par->node()->children.push_back(p);
        p->AddRef();
    } else if (n->parent == par) {
        // réordonne : remet en fin de liste (ordre DFS = z-order)
        auto& sibs = par->node()->children;
        for (auto sit = sibs.begin(); sit != sibs.end(); ++sit)
            if (*sit == p) { sibs.erase(sit); sibs.push_back(p); break; }
    }
    b->seen.push_back(p);
    return 0;
}

int kx_a11y_sync_end(void* view) {
    HWND hwnd = (HWND)view;
    if (!hwnd) return 0;
    std::lock_guard<std::mutex> lk(g_mtx);
    KxBridge* b = bridgeFor(hwnd);
    pruneUnseen(b);
    const int mutated = (b->structural_mut || b->props_mut) ? 1 : 0;
    DBG("sync_end hwnd=%p items=%zu mutated=%d listening=%d\n", hwnd,
        b->seen.size(), mutated, (int)UiaClientsAreListening());

    if (!b->root) {   // première sync sans item : rien à publier
        return mutated;
    }

    // Notifs : structure → StructureChanged ; props-seules → LayoutInvalidated.
    if (b->structural_mut && UiaClientsAreListening()) {
        b->root->AddRef();
        UiaRaiseAutomationEvent(
            static_cast<IRawElementProviderSimple*>(b->root),
            UIA_StructureChangedEventId);
        b->root->Release();
    } else if (b->props_mut && UiaClientsAreListening()) {
        b->root->AddRef();
        UiaRaiseAutomationEvent(
            static_cast<IRawElementProviderSimple*>(b->root),
            UIA_LayoutInvalidatedEventId);
        b->root->Release();
    }

    // Delta focus → HasKeyboardFocus property change sur les deux éléments.
    void* now_focus = nullptr;
    for (auto& kv : b->by_ident)
        if (kv.second->node() && (kv.second->node()->flags & 4))
            now_focus = kv.first;
    if (now_focus != b->last_focus_ident) {
        if (UiaClientsAreListening()) {
            VARIANT ov, nv;
            VariantInit(&ov); ov.vt = VT_BOOL; ov.boolVal = VARIANT_FALSE;
            VariantInit(&nv); nv.vt = VT_BOOL; nv.boolVal = VARIANT_TRUE;
            auto raiseFocus = [&](void* ident, VARIANT oldV, VARIANT newV) {
                auto fit = b->by_ident.find(ident);
                if (fit == b->by_ident.end()) return;
                KxProvider* p = fit->second;
                p->AddRef();
                UiaRaiseAutomationPropertyChangedEvent(
                    static_cast<IRawElementProviderSimple*>(p),
                    UIA_HasKeyboardFocusPropertyId, oldV, newV);
                p->Release();
            };
            if (b->last_focus_ident)
                raiseFocus(b->last_focus_ident, nv, ov);
            if (now_focus)
                raiseFocus(now_focus, ov, nv);
        }
        b->last_focus_ident = now_focus;
    }
    return mutated;
}

// Enregistre le handler d'action (Invoke→0, RangeValue delta→1|2).
// view=HWND : bridge de cette fenêtre ; view=nullptr : handler global
// (pattern Android) appliqué à tous les bridges existants et futurs.
void kx_a11y_set_action_handler(void* view, kx_a11y_action_cb cb, void* ctx) {
    std::lock_guard<std::mutex> lk(g_mtx);
    if (!view) {
        g_default_cb = cb;
        g_default_ctx = ctx;
        for (auto& kv : g_bridges) {
            if (!kv.second->action_cb) {
                kv.second->action_cb = cb;
                kv.second->action_ctx = ctx;
            }
        }
        return;
    }
    KxBridge* b = bridgeFor((HWND)view);
    b->action_cb = cb;
    b->action_ctx = ctx;
}

// Vide l'arbre (fenêtre détruite ou shutdown) — drop toutes les refs.
void kx_a11y_clear(void* view) {
    HWND hwnd = (HWND)view;
    if (!hwnd) return;
    std::lock_guard<std::mutex> lk(g_mtx);
    auto it = g_bridges.find(hwnd);
    if (it == g_bridges.end()) return;
    KxBridge* b = it->second;
    if (b->root) {
        // Détruit la racine : les providers se libèrent via les refs.
        b->root->Release();
        b->root = nullptr;
    }
    b->by_ident.clear();
    b->seen.clear();
    b->last_focus_ident = nullptr;
}

// Hit-test : déjà assuré par ElementProviderFromPoint du fragment root —
// rien à installer sous Windows (contrairement à l'AX de macOS).
int kx_a11y_install_hittest(void* view) {
    (void)view;
    return 0;
}

void kx_a11y_debug_dump(void* view) {
    HWND hwnd = (HWND)view;
    std::lock_guard<std::mutex> lk(g_mtx);
    auto it = g_bridges.find(hwnd);
    if (it == g_bridges.end() || !it->second->root) {
        fprintf(stderr, "[a11y] dump hwnd=%p : pas d'arbre\n", (void*)hwnd);
        return;
    }
    KxBridge* b = it->second;
    fprintf(stderr, "[a11y] dump hwnd=%p nodes=%zu\n", (void*)hwnd,
            b->by_ident.size());
    std::vector<std::pair<KxProvider*, int>> stack;
    stack.push_back({b->root, 0});
    while (!stack.empty()) {
        auto [p, depth] = stack.back(); stack.pop_back();
        KxNode* n = p->node();
        if (n) {
            fprintf(stderr, "%*s[%d] role=%d flags=%d '%ls' (%.0f,%.0f %.0fx%.0f)\n",
                    depth * 2, "", n->rid, n->role, n->flags,
                    n->label.c_str(), n->x, n->y, n->w, n->h);
            auto& kids = p->childrenOf();
            for (auto kit = kids.rbegin(); kit != kids.rend(); ++kit)
                stack.push_back({*kit, depth + 1});
        }
    }
    fflush(stderr);
}

// Activation directe par ident (diagnostic) : cb(ctx, ident, 0).
int kx_a11y_activate_ident(void* view, void* ident) {
    HWND hwnd = (HWND)view;
    kx_a11y_action_cb cb;
    void* ctx;
    bool exists = false;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        auto it = g_bridges.find(hwnd);
        if (it == g_bridges.end()) return 0;
        KxBridge* b = it->second;
        exists = b->by_ident.count(ident) > 0;
        cb = b->action_cb ? b->action_cb : g_default_cb;
        ctx = b->action_cb ? b->action_ctx : g_default_ctx;
    }
    if (!exists || !cb || !ident) return 0;
    cb(ctx, ident, 0);
    return 1;
}

} // extern "C"
