# K2-macOS — bridge NSAccessibility complet (arbre sémantique → AX)

**Plateforme** : macOS 26.5.2 arm64, M4 Pro (Virtual), Xcode CLT
**Statut** : PASS — arbre imbriqué + bounds exactes + hit-test installé + notifications + idempotence, prouvés via System Events sur la fenêtre réelle.

## ABI figée (déclarée dans `kx_skia.h`)

```c
typedef enum kx_a11y_role {
    KX_A11Y_GENERIC = 0, KX_A11Y_BUTTON = 1, KX_A11Y_CHECKBOX = 2,
    KX_A11Y_SLIDER = 3, KX_A11Y_TEXTFIELD = 4, KX_A11Y_LIST = 5,
    KX_A11Y_LISTITEM = 6, KX_A11Y_HEADING = 7, KX_A11Y_GROUP = 8,
} kx_a11y_role;
enum { KX_A11Y_DISABLED=1, KX_A11Y_FOCUSABLE=2, KX_A11Y_FOCUSED=4, KX_A11Y_SELECTED=8 };

int  kx_a11y_sync_begin(void* nsview, double scale);  // scale = drawable_px / logical_pt
int  kx_a11y_sync_item(void* nsview, void* ident, void* parent_ident,
                       int role, const char* label, const char* hint,
                       double x, double y, double w, double h, unsigned flags);
int  kx_a11y_sync_end(void* nsview);                  // retourne 1 si arbre muté
void kx_a11y_clear(void* nsview);
int  kx_a11y_install_hittest(void* nsview);           // 1=installé, 0=déjà impl, -1=null
```

**Contrat côté Zig (host.zig/gallery)** :
- `ident` = `SemItem.node*` (clé stable tant que le node vit). parent_ident=0 → enfant direct de la vue.
- **Push parents avant enfants** — le frame parent-relatif de l'enfant est résolu contre l'origine absolue du parent déjà poussé.
- Strings UTF-8 : **copiées par le shim** (le caller garde ses buffers, pas de rétention).
- x,y,w,h en **pixels physiques** (pw/ph du layout, exactement la sortie de `collectSemantics`) — le shim divise par `scale` puis applique le flip Y si la vue n'est pas `isFlipped` (SDL_MetalView EST flipped → pas de flip appliqué, vérifié).
- Appeler `kx_a11y_install_hittest(view)` une fois au setup (idempotent, verdict en retour — consigner).

## Implémentation (`shim/kx_a11y.mm`)

- **Rebuild-avec-reuse** : état par vue via associated object (`NSMutableDictionary` id→NSAccessibilityElement). `sync_item` réutilise l'élément existant et ne réécrit un attribut que s'il change → le focus AX survit aux rebuilds, et `mutated` ne se lève que sur vraie différence. `sync_end` supprime les ids non revus, reconstruit `accessibilityChildren` (roots sur la vue + groupage par `accessibilityParent`).
- **Bounds parent-relatives** : `accessibilityFrameInParentSpace` est relatif au **parent AX**, pas à la vue (mesuré : enfant du groupe reporté à +origine_groupe). Le shim calcule le rect absolu dans l'espace vue puis soustrait l'origine absolue du parent (chaîne remontée jusqu'à la vue, garde 64 niveaux).
- **Flags** : disabled→`accessibilityEnabled=NO` ; focusable|focused→`setAccessibilityElement:YES` (exposé au nav) ; focused→`accessibilityFocused` + mémorisé pour la notification ; selected→`accessibilitySelected`.
- **Notifications** : `AXLayoutChangedNotification` posté sur la vue quand `mutated` ; `AXFocusedUIElementChangedNotification` posté sur le nouvel élément quand `pendingFocused` change entre syncs.
- **Hit-test** : `kx_hit_test` parcourt `accessibilityChildren` (ordre z = ordre de sync, dernier contenant gagne) et retourne l'élément, sinon délègue à l'impl `NSView` par `instanceMethodForSelector`. Install via `class_addMethod` sur la classe de la vue — verdict : **SDL_MetalView n'implémente pas `accessibilityHitTest` → class_addMethod a réussi, aucun swizzle (plan B non déclenché).** Si une vue implémentait déjà le getter, `kx_a11y_install_hittest` retourne 0 et rien n'est modifié (verdict à consigner).

## Preuves (fenêtre réelle, System Events `UI elements of window`)

```
a11y sync rc=1 (2nd=0) hittest=1
AXHeading | kx demo      | 576 180 | 448 32
AXGroup   | kx card grid | 576 220 | 448 560
   AXButton | kx play   | 750 832 | 100 44   ← bounds exactes parent-relatives
   AXButton | kx stop   | 860 832 | 100 44
AXTextField| kx status  | 576 932 | 448 24
```
Fenêtre à (560,140), titlebar 32pt : play (190,660 view) → écran (750,832) ✓ exact au point près. Groupe imbriqué contient bien les 2 boutons (chemin `parent_ident` prouvé).
- **rc=1** première sync (arbre construit), **rc=0** seconde sync identique (reuse, pas de mutation → pas de notification superflue).
- **hittest=1** : install propre, log `kx_hit_test` présent dans le shim (vérifié dans le source ; l'observation runtime requiert un client AX — VoiceOver, voir limites).
- Éléments natifs SDL conservés (close/minimize/fullscreen/AXStaticText) — le bridge ajoute, ne remplace pas.

## Pièges & honnêteté

1. `accessibilityFrameInParentSpace` ≠ espace vue : c'est l'espace du **parent AX** — bug corrigé ci-dessus, mesuré avant/après (766→750 en x).
2. `NSAccessibilityElement` sur macOS 26 : `init` plain + `.accessibilityRole=` (le `initWithAccessibilityRole:` n'existe pas).
3. `@selector(accessibilityHitTest:)` encodé `"@@:{CGPoint=dd}"` — retour object + param struct. Fallback `NSView` invoqué via IMP (pas de `[super]` possible hors d'une vraie méthode de classe).
4. scale=1.00 sur cette VM (pas de backing 2x à l'écran virtuel) — le chemin `/scale` est écrit mais non exercé en Retina réel.
5. `NSAccessibilityPostNotification` vérifié au code level (posté sur la vue/élément — API correcte) ; un client AX (VoiceOver) est requis pour observer la réception — VoiceOver activable sur la VM mais son toggle modifie les réglages du test, non fait ici.
6. `pendingRoots` conserve l'ordre de sync (z-order) pour les roots ; le hit-test prend le dernier contenant (top-most).
7. iOS : même forme (UIAccessibilityElement + `accessibilityFrame` absolu écran) — API quasi-identique, port trivial mais **non testé** (hors mandat macOS).
8. Thread : tout le code AX est appelé depuis la boucle principale SDL — `sync_*` non thread-safe par design (documenter: appeler depuis le main thread).

## Fichiers livrés

- `shim/kx_a11y.mm` — bridge complet (state par vue, sync begin/item/end, absViewOrigin, hit-test, notifications, clear)
- `kx_skia.h` — bloc a11y ajouté (enum role/flags + 5 prototypes + contrat d'ordre)
- `main.zig` — démo : install_hittest + push arbre 5 items (heading/groupe/2 boutons/textfield, focused sur play) + 2e sync idempotente
- `results/k2-a11y-run.log` — sortie `rc=1 (2nd=0) hittest=1` + arbre AX dumpé

---

## Suite — actions AX (lot 2) + régression FontCollection lazy (lot 1)

### Actions : `kx_a11y_set_action_handler` — AXPress route jusqu'à Zig

```c
typedef void (*kx_a11y_action_cb)(void* ctx, void* node_ident, int action);
void kx_a11y_set_action_handler(void* nsview, kx_a11y_action_cb cb, void* ctx);
```

- action 0=press, 1=increment, 2=decrement. Rôles button/checkbox/textfield/
  listitem → `AXPress` seul ; slider → +`AXIncrement`/`AXDecrement`.
- Implémentation : sous-classe `KxA11yElement : NSAccessibilityElement` —
  `accessibilityActionNames` (par rôle) + `accessibilityPerformPress/
  Increment/Decrement` → cb sur le main thread. `kxIdent` = l'id du sync_item
  (SemItem.node* côté collectSemantics).
- host.zig : `kx_a11y_install_hittest` + `kx_a11y_set_action_handler(view,
  axTrampoline, NULL)` dans `initMetalWindow` ; trampoline → hook global
  `host.ax_action_user` (l'app mappe ident→node→ui.hit centre-bounds).
- Vérif System Events : `perform action "AXPress"` sur "kx play"/"kx stop".

**Preuve par effet réel (mode rest, 0 frame sans event)** :
- `ax action ident=0xa3 action=0` (play) → scène s5 présentée (blur stack).
- `ax action ident=0xa4 action=0` (stop) → retour s1 (card grid).
- Captures : `ax_before.png` (s1) / `ax_after_press.png` (s5) / `ax_after_stop.png` (s1).
- JSON : `ax_actions=2`, `frames=4` (les 2 presses ont déclenché les draws —
  le dirty-loop les compte comme frames honnêtes).
- Détail utile : SE liste `AXPress/AXIncrement/AXDecrement` sur le bouton —
  AppKit expose aussi les actions héritées de protocole ; press marche.

### Régression FontCollection lazy (lot 1)

- Patch porté : `collection_dirty` dans kx_fonts_add ; rebuild unique dans
  `kx_fonts_collection` (+ fallback si jamais construite). `kx_fonts_add_dir`
  ajouté (scan .ttf/.otf/.ttc/.dfont, count en retour).
- Rendu : corpus 9/9 PASS post-patch (s2 texte mae=3.05, s7 mae=0.02 — inchangé).
- Timing `/System/Library/Fonts` (80 fontes) : `add_dir=1016ms` (~12.7ms/fonte,
  dominé par parse SkTypeface+I/O), `collection_rebuild` 1re lecture = **<0.1ms**
  — la collection est un wrap trivial du mgr+families, le gain lazy = éviter
  N rebuilds, pas un rebuild cher. Mesure honnête : pas d'ancien chiffre N×
  rebuild (patch arrivé avant la mesure), mais le coût/add est minime.
- `test_fontdir` : mini harnais C++ de mesure (80 fontes, JSON ci-dessus).
