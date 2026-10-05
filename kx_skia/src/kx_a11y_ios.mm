// kx_a11y_ios.mm — bridge arbre sémantique klaxon → UIAccessibility (iOS).
// Contrat gelé commun à toutes les plateformes :
//   kx_a11y_sync_begin(view, scale)
//   kx_a11y_sync_item(view, ident, parent_ident, role, label, hint, x,y,w,h, flags) ×N
//   kx_a11y_sync_end(view)  → 1 si muté
//   kx_a11y_set_action_handler(view, cb(ctx, ident, action), ctx)
// role : 0 generic 1 button 2 checkbox 3 slider 4 textfield 5 list
//        6 listitem 7 heading 8 group
// flags : 1 DISABLED | 2 FOCUSABLE | 4 FOCUSED | 8 SELECTED
// ident : pointeur opaque (node* zig — jamais déréférencé, clé de pool).
// bounds : pixels device absolus ; ÷scale → points container-space
//          (accessibilityFrameInContainerSpace — UIKit convertit en écran,
//          plus propre que la soustraction parent-space de macOS).
// Main-thread only. Strings UTF-8 copiées à sync_item.
// Vérifié sim iPhone 17/iOS 26.5 : 39 éléments, traits mesurés,
// LayoutChanged posté sur mutation, activate→callback→tap chaîne complète.

#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif
#import <Foundation/Foundation.h>

@class KXAxState;

@interface KXAxElement : UIAccessibilityElement
@property(nonatomic, assign) void* ident;
@property(nonatomic, assign) KXAxState* state;
@end

@interface KXAxState : NSObject
@property(nonatomic) UIView* view;
@property(nonatomic) double scale;
@property(nonatomic) NSMutableDictionary<NSNumber*, KXAxElement*>* pool;
@property(nonatomic) NSMutableSet<NSNumber*>* seen;
@property(nonatomic) NSMutableArray<UIAccessibilityElement*>* order;
@property(nonatomic) KXAxElement* focused;
@property(nonatomic) BOOL treeNonEmpty;
@property(nonatomic) BOOL mutated;
@property(nonatomic) void (*cb)(void* ctx, void* ident, int action);
@property(nonatomic) void* cbCtx;
@end

@implementation KXAxElement
- (BOOL)accessibilityActivate {
    if (self.state.cb) self.state.cb(self.state.cbCtx, self.ident, 0);
    return YES;
}
- (void)accessibilityIncrement {
    if (self.state.cb) self.state.cb(self.state.cbCtx, self.ident, 1);
}
- (void)accessibilityDecrement {
    if (self.state.cb) self.state.cb(self.state.cbCtx, self.ident, 2);
}
@end

@implementation KXAxState
@end

static KXAxState* stFor(void* v, BOOL create) {
    static NSMapTable* states = nil;  // view → state (weak keys)
    if (!states) states = [NSMapTable weakToStrongObjectsMapTable];
    UIView* view = (__bridge UIView*)v;
    KXAxState* st = [states objectForKey:view];
    if (!st && create) {
        st = [KXAxState new];
        st.view = view;
        st.pool = [NSMutableDictionary new];
        view.isAccessibilityElement = NO;  // seuls nos éléments parlent
        [states setObject:st forKey:view];
    }
    return st;
}

static UIAccessibilityTraits traitsFor(int role, int flags, BOOL* isElement) {
    UIAccessibilityTraits t = UIAccessibilityTraitNone;
    *isElement = YES;
    switch (role) {
        case 1: t = UIAccessibilityTraitButton; break;              // button
        case 2: t = UIAccessibilityTraitButton; break;              // checkbox ≈ button + selected
        case 3: t = UIAccessibilityTraitAdjustable; break;          // slider
        case 4: t = UIAccessibilityTraitNone; break;                // textfield : element + label
        case 5: *isElement = NO; t = UIAccessibilityTraitNone; break; // list : container
        case 6:  // listitem : StaticText, ou Button si focusable
            t = (flags & 2) ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
            break;
        case 7: t = UIAccessibilityTraitHeader; break;              // heading
        case 8: *isElement = NO; t = UIAccessibilityTraitNone; break; // group : container
        default: t = UIAccessibilityTraitStaticText; break;         // generic
    }
    if (flags & 1) t |= UIAccessibilityTraitNotEnabled;   // DISABLED
    if (flags & 8) t |= UIAccessibilityTraitSelected;     // SELECTED
    return t;
}

extern "C" {

int kx_a11y_sync_begin(void* view, double scale) {
    if (!view || !NSThread.isMainThread) return 0;
    KXAxState* st = stFor(view, YES);
    st.scale = scale > 0 ? scale : 1.0;
    st.seen = [NSMutableSet new];
    st.order = [NSMutableArray new];
    st.focused = nil;
    st.mutated = NO;
    return 0;
}

int kx_a11y_sync_item(void* view, void* ident, void* parent_ident,
                       int role, const char* label, const char* hint,
                       double x, double y, double w, double h, unsigned flags) {
    (void)parent_ident;  // arbre plat — la hiérarchie vit dans l'ordre DFS
    if (!view || !ident || !NSThread.isMainThread) return 0;
    KXAxState* st = stFor(view, YES);
    if (!st.seen) return 0;  // sync_item hors begin → ignoré
    NSNumber* key = @((uint64_t)(uintptr_t)ident);
    [st.seen addObject:key];
    KXAxElement* el = st.pool[key];
    if (!el) {
        // Piège iOS : `new` jette 'Use initWithAccessibilityContainer:' —
        // le container fixe aussi le repère de accessibilityFrameInContainerSpace.
        el = [[KXAxElement alloc] initWithAccessibilityContainer:st.view];
        el.ident = ident;
        el.state = st;
        st.pool[key] = el;
        st.mutated = YES;
    }
    const double s = st.scale;
    CGRect pts = CGRectMake(x / s, y / s, w / s, h / s);
    if (!CGRectEqualToRect(el.accessibilityFrameInContainerSpace, pts)) {
        el.accessibilityFrameInContainerSpace = pts;
        st.mutated = YES;
    }
    NSString* lb = label ? @(label) : @"";
    NSString* hn = hint ? @(hint) : @"";
    if (![el.accessibilityLabel isEqualToString:lb]) { el.accessibilityLabel = lb; st.mutated = YES; }
    if (![el.accessibilityHint isEqualToString:hn]) { el.accessibilityHint = hn; st.mutated = YES; }
    BOOL isEl = YES;
    UIAccessibilityTraits t = traitsFor(role, flags, &isEl);
    if (el.accessibilityTraits != t) { el.accessibilityTraits = t; st.mutated = YES; }
    if (el.isAccessibilityElement != isEl) { el.isAccessibilityElement = isEl; st.mutated = YES; }
    if (flags & 4) st.focused = el;  // FOCUSED
    [st.order addObject:el];
    return 0;
}

int kx_a11y_sync_end(void* view) {
    if (!view || !NSThread.isMainThread) return 0;
    KXAxState* st = stFor(view, NO);
    if (!st || !st.seen) return 0;
    // prune : éléments absents de cette génération
    for (NSNumber* k in st.pool.allKeys)
        if (![st.seen containsObject:k]) { [st.pool removeObjectForKey:k]; st.mutated = YES; }
    UIView* vw = st.view;
    NSArray* prev = vw.accessibilityElements;
    if (![prev isEqualToArray:st.order]) st.mutated = YES;
    vw.accessibilityElements = st.order;  // DFS = top→down
    st.seen = nil;
    if (st.order.count == 0) return st.mutated ? 1 : 0;
    BOOL firstTree = !st.treeNonEmpty;
    st.treeNonEmpty = YES;
    if (firstTree) {
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
        st.mutated = YES;
    } else if (st.mutated) {
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
                                        st.focused ?: nil);
    }
    return st.mutated ? 1 : 0;
}

void kx_a11y_clear(void* view) {
    if (!view) return;
    KXAxState* st = stFor(view, NO);
    if (!st) return;
    [st.pool removeAllObjects];
    st.view.accessibilityElements = nil;
    st.treeNonEmpty = NO;
}

// iOS : le hit-test VoiceOver traverse accessibilityElements par frames —
// pas d'injection de méthode nécessaire (contrairement à macOS NSView).
int kx_a11y_install_hittest(void* nsview) {
    (void)nsview;
    return 1;  // installé = path natif (rien à brancher)
}

void kx_a11y_set_action_handler(void* view,
                                void (*cb)(void* ctx, void* ident, int action),
                                void* ctx) {
    if (!view) return;
    KXAxState* st = stFor(view, YES);
    st.cb = cb;
    st.cbCtx = ctx;
}

// Sonde de vérif programmatique (harnais — pas dans le contrat). Dump
// elements + traits + frames écran, puis activate le premier Button.
void kx_a11y_debug_dump(void* view) {
    if (!view) return;
#if TARGET_OS_IOS
    KXAxState* st = stFor(view, NO);
    UIView* vw = st ? st.view : (__bridge UIView*)view;
    NSArray* els = vw.accessibilityElements;
    NSLog(@"[a11y] dump: %lu elements", (unsigned long)els.count);
    [els enumerateObjectsUsingBlock:^(UIAccessibilityElement* e, NSUInteger i, BOOL* stop) {
        CGRect f = e.accessibilityFrame;  // coords écran
        NSLog(@"[a11y] #%lu ident=%p traits=0x%llx label='%@' frame=%.0f,%.0f %.0fx%.0f",
              (unsigned long)i,
              [e isKindOfClass:KXAxElement.class] ? ((KXAxElement*)e).ident : (void*)0,
              (unsigned long long)e.accessibilityTraits,
              e.accessibilityLabel, f.origin.x, f.origin.y, f.size.width, f.size.height);
    }];
    for (UIAccessibilityElement* e in els) {
        if (e.accessibilityTraits & UIAccessibilityTraitButton) {
            NSLog(@"[a11y] activate test → button '%@'", e.accessibilityLabel);
            BOOL ok = [e accessibilityActivate];
            NSLog(@"[a11y] accessibilityActivate → %d", ok);
            break;
        }
    }
#else
    (void)view;
#endif
}

// Helper harnais : déclenche accessibilityActivate sur l'élément `ident`
// (équivalent au double-tap VoiceOver). 1 si l'élément existait.
int kx_a11y_activate_ident(void* view, void* ident) {
    if (!view || !ident) return 0;
#if TARGET_OS_IOS
    KXAxState* st = stFor(view, NO);
    if (!st) return 0;
    KXAxElement* el = st.pool[@((uint64_t)(uintptr_t)ident)];
    if (!el) return 0;
    return [el accessibilityActivate] ? 1 : 0;
#else
    return 0;
#endif
}

}  // extern "C"
