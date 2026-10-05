// kx_a11y.mm — bridge K2 : arbre sémantique plat Klaxon → NSAccessibilityElement
// sur le NSView hôte (SDL_MetalView est un NSView).
//
// Cycle de sync (appelé depuis Zig quand collectSemantics change) :
//   kx_a11y_sync_begin(view, scale)          — scale = drawable_px / logical_pt
//   kx_a11y_sync_item(view, id, parent, role, label, hint, x,y,w,h, flags) ×N
//   kx_a11y_sync_end(view)                   — applique + notifications
//
// `id` est une clé stable (SemItem.node*) : les éléments sont réutilisés entre
// syncs (rebuild-avec-reuse), préservant le focus AX. parent_id=0 → enfant
// direct de la vue. Strings UTF-8 COPIÉES par le shim (le caller garde ses
// buffers). Bounds en px physiques → converties en points via /scale, puis en
// coords view (flip Y si la vue n'est pas isFlipped).
//
// Notifications : AXLayoutChangedNotification quand l'arbre a muté entre deux
// sync_end ; AXFocusedUIElementChangedNotification quand l'élément focused
// change. Hit-test : class_addMethod(accessibilityHitTest:) sur la classe de
// la vue si elle ne le surcharge pas déjà (verdict consigné via retour de
// kx_a11y_install_hittest).
//
// ACTIONS : kx_a11y_set_action_handler(view, cb, ctx) enregistre un handler
// invoqué sur le main thread — cb(ctx, ident, action) ; action 0 = press,
// 1 = increment, 2 = decrement (slider seulement). Les éléments sont créés
// via KxA11yElement (sous-classe NSAccessibilityElement) qui expose
// accessibilityActionNames/Perform* selon le rôle.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

typedef void (*kx_a11y_action_cb)(void* ctx, void* node_ident, int action);

// ---- État par vue (faible, nettoyé avec la vue via associated object) ------

@interface KxA11yElement : NSAccessibilityElement
@property(nonatomic) void* kxIdent;
@property(nonatomic, unsafe_unretained) id kxState; // KxA11yState (MRC)
@property(nonatomic, copy) NSArray<NSString*>* kxActions; // rôles→actions
@end

// ---- État par vue (faible, nettoyé avec la vue via associated object) ------

@interface KxA11yState : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSAccessibilityElement*>* all;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* order;      // ordre z de la sync courante
@property(nonatomic, strong) NSMutableSet<NSNumber*>* seen;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* roots;      // dernière liste appliquée
@property(nonatomic, strong) NSMutableArray<NSNumber*>* pendingRoots;
@property(nonatomic, strong) NSNumber* focusedId;
@property(nonatomic, strong) NSNumber* pendingFocused;
@property(nonatomic) double scale;
@property(nonatomic) BOOL inSync;
@property(nonatomic) BOOL mutated;                                   // ajout/remove/attributs
@property(nonatomic) kx_a11y_action_cb handler;
@property(nonatomic) void* handlerCtx;
@end
@implementation KxA11yState @end

@implementation KxA11yElement
- (NSArray<NSString*>*)accessibilityActionNames {
    return self.kxActions ? self.kxActions : @[];
}
- (BOOL)accessibilityPerformPress {
    KxA11yState* s = (KxA11yState*)self.kxState;
    if (!s || !s.handler) return NO;
    s.handler(s.handlerCtx, self.kxIdent, 0);
    return YES;
}
- (BOOL)accessibilityPerformIncrement {
    KxA11yState* s = (KxA11yState*)self.kxState;
    if (!s || !s.handler) return NO;
    s.handler(s.handlerCtx, self.kxIdent, 1);
    return YES;
}
- (BOOL)accessibilityPerformDecrement {
    KxA11yState* s = (KxA11yState*)self.kxState;
    if (!s || !s.handler) return NO;
    s.handler(s.handlerCtx, self.kxIdent, 2);
    return YES;
}
@end

static const void* kKxA11yStateKey = &kKxA11yStateKey;

static KxA11yState* stateFor(NSView* v, BOOL create) {
    KxA11yState* s = objc_getAssociatedObject(v, kKxA11yStateKey);
    if (!s && create) {
        s = [KxA11yState new];
        s.all = [NSMutableDictionary new];
        s.scale = 1.0;
        objc_setAssociatedObject(v, kKxA11yStateKey, s,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static NSArray<NSString*>* actionsForRole(int role) {
    switch (role) {
        case 3: // slider : press + inc/dec
            return @[NSAccessibilityPressAction, NSAccessibilityIncrementAction,
                     NSAccessibilityDecrementAction];
        case 1: case 2: case 4: case 6: // button/checkbox/textfield/listitem
            return @[NSAccessibilityPressAction];
        default:
            return @[];
    }
}

static NSString* mapRole(int role) {
    switch (role) {
        case 1: return NSAccessibilityButtonRole;
        case 2: return NSAccessibilityCheckBoxRole;
        case 3: return NSAccessibilitySliderRole;
        case 4: return NSAccessibilityTextFieldRole;
        case 5: return NSAccessibilityListRole;
        case 6: return NSAccessibilityCellRole;      // listitem
        case 7: return @"AXHeading";                 // pas de constante publique
        case 8: return NSAccessibilityGroupRole;
        default: return NSAccessibilityGroupRole;    // generic
    }
}

/// Origine absolue (espace vue) d'un élément : somme des frameInParentSpace de
/// la chaîne jusqu'à la vue (chaque frame est relative à son parent AX).
static NSPoint absViewOrigin(NSAccessibilityElement* el, NSView* v) {
    NSPoint o = el.accessibilityFrameInParentSpace.origin;
    id p = el.accessibilityParent;
    int guard = 0;
    while (p && p != (id)v && [p isKindOfClass:[NSAccessibilityElement class]] && guard++ < 64) {
        NSPoint pp = ((NSAccessibilityElement*)p).accessibilityFrameInParentSpace.origin;
        o.x += pp.x; o.y += pp.y;
        p = ((NSAccessibilityElement*)p).accessibilityParent;
    }
    return o;
}

// ---- Hit-test : ajouté à la classe de la vue si elle ne l'implémente pas ----

static NSMapTable<NSValue*, NSNumber*>* gHitInstalled; // classe -> verdict

static id kx_hit_test(id self, SEL _cmd, NSPoint pt) {
    NSView* v = (NSView*)self;
    KxA11yState* s = objc_getAssociatedObject(v, kKxA11yStateKey);
    if (s) {
        // Dernier élément le plus profond contenant pt (z-order = ordre de sync).
        NSArray* kids = v.accessibilityChildren;
        for (NSInteger i = (NSInteger)kids.count - 1; i >= 0; --i) {
            NSAccessibilityElement* el = kids[i];
            NSRect f = el.accessibilityFrameInParentSpace;
            if (NSPointInRect(pt, f)) return el;
        }
    }
    // Fallback : impl de NSView (classe parente réelle de la vue).
    IMP sup = [NSView instanceMethodForSelector:@selector(accessibilityHitTest:)];
    return ((id (*)(id, SEL, NSPoint))sup)(self, _cmd, pt);
}

extern "C" {

/// Enregistre le handler d'actions AX (press/inc/dec) invoqué main-thread.
/// Répétable : le dernier appel remplace handler+ctx. cb NULL = désarme.
void kx_a11y_set_action_handler(void* nsview, kx_a11y_action_cb cb, void* ctx) {
    NSView* v = (__bridge NSView*)nsview;
    KxA11yState* s = stateFor(v, YES);
    s.handler = cb;
    s.handlerCtx = ctx;
}

/// Installe accessibilityHitTest sur la vue hôte.
/// Retour : 1 = ajouté (class_addMethod), 0 = déjà implémenté par la classe
/// (swizzle refusé — on ne casse pas l'impl SDL), -1 = vue null.
int kx_a11y_install_hittest(void* nsview) {
    NSView* v = (__bridge NSView*)nsview;
    if (!v) return -1;
    if (!gHitInstalled) gHitInstalled = [NSMapTable strongToStrongObjectsMapTable];
    Class cls = object_getClass(v);
    NSValue* key = [NSValue valueWithPointer:(__bridge const void*)cls];
    if ([gHitInstalled objectForKey:key])
        return [[gHitInstalled objectForKey:key] intValue];

    // La classe implémente-t-elle elle-même le getter ? (héritage ne compte pas)
    unsigned n = 0;
    Method* methods = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned i = 0; i < n; ++i)
        if (method_getName(methods[i]) == @selector(accessibilityHitTest:)) own = YES;
    free(methods);

    int verdict = 0;
    if (!own) {
        BOOL ok = class_addMethod(cls, @selector(accessibilityHitTest:),
                                  (IMP)kx_hit_test, "@@:{CGPoint=dd}");
        verdict = ok ? 1 : 0;
    }
    [gHitInstalled setObject:@(verdict) forKey:key];
    return verdict;
}

// ---- API de sync -----------------------------------------------------------

int kx_a11y_sync_begin(void* nsview, double scale) {
    NSView* v = (__bridge NSView*)nsview;
    if (!v) return -1;
    KxA11yState* s = stateFor(v, YES);
    s.inSync = YES;
    s.mutated = NO;
    s.scale = scale > 0 ? scale : 1.0;
    s.seen = [NSMutableSet new];
    s.order = [NSMutableArray new];
    s.pendingRoots = [NSMutableArray new];
    s.pendingFocused = nil;
    return 0;
}

int kx_a11y_sync_item(void* nsview, void* ident, void* parent_ident,
                      int role, const char* label, const char* hint,
                      double x, double y, double w, double h,
                      unsigned flags) {
    NSView* v = (__bridge NSView*)nsview;
    KxA11yState* s = v ? stateFor(v, NO) : nil;
    if (!v || !s || !s.inSync || !ident) return -1;
    NSNumber* key = @((unsigned long long)(uintptr_t)ident);
    [s.seen addObject:key];
    [s.order addObject:key];

    NSAccessibilityElement* el = s.all[key];
    if (!el) {
        KxA11yElement* kel = [[KxA11yElement alloc] init];
        kel.kxState = s;
        el = kel;
        s.all[key] = el;
        s.mutated = YES;
    }
    if ([el isKindOfClass:[KxA11yElement class]])
        ((KxA11yElement*)el).kxIdent = ident; // placeholder parent → vrai ident

    // Attributs : ne réécrit que si changé (mutated honest).
    NSString* nsRole = mapRole(role);
    if (![el.accessibilityRole isEqualToString:nsRole]) {
        el.accessibilityRole = nsRole;
        s.mutated = YES;
    }
    if ([el isKindOfClass:[KxA11yElement class]])
        ((KxA11yElement*)el).kxActions = actionsForRole(role);
    NSString* nsLabel = label ? @(label) : @"";
    if (![el.accessibilityLabel isEqualToString:nsLabel]) {
        el.accessibilityLabel = nsLabel;
        s.mutated = YES;
    }
    NSString* nsHint = hint ? @(hint) : nil;
    if (nsHint && ![el.accessibilityHelp isEqualToString:nsHint]) {
        el.accessibilityHelp = nsHint;
        s.mutated = YES;
    }

    // px physiques → points → coords view (flip Y si vue non-flipped), puis
    // relatif au parent AX : accessibilityFrameInParentSpace s'exprime dans
    // l'espace de accessibilityParent (mesuré : bouton enfant du groupe
    // reporté à +16,+420 = origine du groupe ajoutée).
    double pts = s.scale;
    NSRect frView = NSMakeRect(x / pts, y / pts, w / pts, h / pts);
    if (![v isFlipped]) {
        frView.origin.y = v.bounds.size.height - frView.origin.y - frView.size.height;
    }
    NSRect fr = frView;
    if (parent_ident) {
        NSNumber* pk = @((unsigned long long)(uintptr_t)parent_ident);
        NSAccessibilityElement* pe = s.all[pk];
        if (pe) {
            // frameInParentSpace = coords relatives au parent AX → soustraire
            // l'origine ABSOLUE du parent (chaîne remontée jusqu'à la vue).
            NSPoint po = absViewOrigin(pe, v);
            fr.origin.x -= po.x;
            fr.origin.y -= po.y;
        }
    }
    NSRect old = el.accessibilityFrameInParentSpace;
    if (!NSEqualRects(old, fr)) {
        el.accessibilityFrameInParentSpace = fr;
        s.mutated = YES;
    }

    // focusable|focused ⇒ exposé dans la nav AX ; disabled → enabled=NO
    [el setAccessibilityElement:((flags & 2) || (flags & 4)) ? YES : NO];
    el.accessibilityEnabled = (flags & 1) == 0;
    BOOL wantFocus = (flags & 4) != 0;
    if (wantFocus) s.pendingFocused = key;
    if ((flags & 8) != 0) el.accessibilitySelected = YES;
    else if (el.accessibilitySelected) el.accessibilitySelected = NO;

    // parent : 0 → vue (root) ; sinon l'élément du parent (déjà vu ou pré-créé).
    if (parent_ident) {
        NSNumber* pk = @((unsigned long long)(uintptr_t)parent_ident);
        NSAccessibilityElement* pe = s.all[pk];
        if (!pe) {
            KxA11yElement* kpe = [[KxA11yElement alloc] init];
            kpe.kxIdent = parent_ident;
            kpe.kxState = s;
            pe = kpe;
            s.all[pk] = pe;
            s.mutated = YES;
        }
        if (el.accessibilityParent != pe) {
            el.accessibilityParent = pe;
            s.mutated = YES;
        }
    } else {
        if (el.accessibilityParent != (id)v) {
            el.accessibilityParent = v;
            s.mutated = YES;
        }
        [s.pendingRoots addObject:key];
    }
    return 0;
}

int kx_a11y_sync_end(void* nsview) {
    NSView* v = (__bridge NSView*)nsview;
    KxA11yState* s = v ? stateFor(v, NO) : nil;
    if (!v || !s || !s.inSync) return -1;
    s.inSync = NO;

    // Suppressions : ids de la table non revus cette sync.
    NSArray* keys = [s.all.allKeys copy];
    for (NSNumber* k in keys) {
        if (![s.seen containsObject:k]) {
            [s.all removeObjectForKey:k];
            s.mutated = YES;
        }
    }

    // Arbre : roots sur la vue + enfants groupés par parent.
    NSMutableArray* newRoots = [NSMutableArray new];
    for (NSNumber* k in s.order)
        if ([s.pendingRoots containsObject:k]) [newRoots addObject:s.all[k]];
    v.accessibilityChildren = newRoots;
    for (NSNumber* k in s.all) {
        NSAccessibilityElement* el = s.all[k];
        NSMutableArray* kids = nil;
        for (NSNumber* ck in s.order) {
            NSAccessibilityElement* ce = s.all[ck];
            if (ce && ce.accessibilityParent == (id)el) {
                if (!kids) kids = [NSMutableArray new];
                [kids addObject:ce];
            }
        }
        el.accessibilityChildren = kids;
    }
    s.roots = newRoots;

    // Focus
    BOOL focusChanged = s.pendingFocused != s.focusedId;
    if (focusChanged) {
        if (s.focusedId) s.all[s.focusedId].accessibilityFocused = NO;
        s.focusedId = s.pendingFocused;
        if (s.focusedId) s.all[s.focusedId].accessibilityFocused = YES;
    }

    // Notifications (postées sur la vue — l'UI change même hors VoiceOver).
    if (s.mutated) {
        NSAccessibilityPostNotification(v, NSAccessibilityLayoutChangedNotification);
    }
    if (focusChanged) {
        NSAccessibilityPostNotification(s.focusedId ? (id)s.all[s.focusedId] : v,
                                        NSAccessibilityFocusedUIElementChangedNotification);
    }
    return s.mutated ? 1 : 0; // 1 = arbre muté
}

void kx_a11y_clear(void* nsview) {
    NSView* v = (__bridge NSView*)nsview;
    if (!v) return;
    v.accessibilityChildren = nil;
    objc_setAssociatedObject(v, kKxA11yStateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---- Helpers harnais (hors contrat) -----------------------------------------

static void dumpEl(id o, int depth) {
    const char* role = [[o valueForKey:@"accessibilityRole"] UTF8String];
    const char* label = [[o valueForKey:@"accessibilityLabel"] UTF8String] ?: "";
    NSValue* fv = [o valueForKey:@"accessibilityFrame"];
    NSRect f = fv ? fv.rectValue : NSZeroRect;
    fprintf(stderr, "%*s%s \"%s\" %.0f,%.0f %.0fx%.0f\n", depth * 2, "",
            role ?: "?", label, f.origin.x, f.origin.y, f.size.width,
            f.size.height);
    NSArray* kids = [o valueForKey:@"accessibilityChildren"];
    for (id k in kids) dumpEl(k, depth + 1);
}

void kx_a11y_debug_dump(void* nsview) {
    NSView* v = (__bridge NSView*)nsview;
    if (!v) { fprintf(stderr, "kx_a11y_dump: null view\n"); return; }
    fprintf(stderr, "kx_a11y_dump %s:\n", [[v className] UTF8String]);
    for (id el in v.accessibilityChildren) dumpEl(el, 1);
}

/// Cherche l'élément dont kxIdent == ident puis performPress programmatique.
int kx_a11y_activate_ident(void* nsview, void* ident) {
    NSView* v = (__bridge NSView*)nsview;
    KxA11yState* s = v ? stateFor(v, NO) : nil;
    if (!v || !s || !ident) return -1;
    NSNumber* key = @((unsigned long long)(uintptr_t)ident);
    NSAccessibilityElement* el = s.all[key];
    if (![el isKindOfClass:[KxA11yElement class]]) return -2;
    return [(KxA11yElement*)el accessibilityPerformPress] ? 0 : -3;
}

} // extern "C"
