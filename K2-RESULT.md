# K2-RESULT — couche widgets/UI de Klaxon (Linux)

Portée : `klaxon/src/ui.zig` (arbre+layout+scroll+LazyList+sémantique+TextField+anim),
`klaxon/src/widgets.zig` (Button/Toggle/Slider/TextFieldView/divider/label),
`gallery/` (app de démo). Host SDL3 dirty-loop, backend ganesh_gles (llvmpipe — VM sans GPU).

## Fait et vérifié

| Élément | Preuve | Statut |
|---|---|---|
| LazyList virtualisée | 10 000 items → **11 slots matérialisés** (`materializations:11`) | PASS |
| Scroll molette | molette xdotool → fenêtre #8–#17 (était #0–#9) | PASS (visuel) |
| Sélection tuile | clic → "Piste #11" surlignée | PASS (visuel) |
| TextField | focus→SDL_StartTextInput+SetTextInputArea, TEXT_INPUT→insert→redraw, "daft punk" affiché + caret positionné (mesure para-préfixe) | PASS (visuel + logs) |
| Modèle d'édition | insert/caret UTF-8/sélection/delete/compose→commit IME — 13/13 tests zig | PASS |
| Arbre sémantique | `Semantics{role,label,hint,focusable,disabled}` + `collectSemantics` DFS→flat+parents — testé | PASS |
| Widgets | Button (tap=up-after-down, états), Toggle, Slider (drag+valeur), divider, label — visuels OK | PASS |
| 0-frame-au-repos | `frames:3` sur 5s, `idle_iters:1168` | PASS |
| JSON stats | tool/backend/driver/frames/materializations/max_slots | PASS |

## Bugs réels trouvés et corrigés

1. **`translate()` ne mappait pas `SDL_EVENT_TEXT_INPUT`** (0x303) : l'event
   était silencieusement droppé → la saisie était morte sur TOUTES les
   plateformes. Détecté via SDL_PushEvent (poll voyait 0x303 non traduit).
2. **Union access panic** dans `syncWindow` : `spacer.size.px` lu alors que
   l'union était `.weight` → champ `last_spacer` à part.
3. **`SDL_EVENT_TEXT_INPUT` constante corrigée** (était 0x302=EDITING → 0x303)
   + structs TextEditingEvent + keycodes ajoutés dans sdl.zig.
4. Font `readFileAlloc` leak → `defer free` (Skia copie).
5. **`host.step` consommait `dirty` APRÈS `draw()`** : tout re-dirty posé dans
   le draw (ex. animation `h.dirty = true` pour continuer la boucle) était
   écrasé → **aucune animation n'aurait jamais pu tourner**, le host retombait
   au repos après 1 frame. Fix : consommer `dirty=false` AVANT `draw()`.
   Prouvé : clic → anim 220ms → `frames:204` (≈220ms×~1.24ms/frame) puis
   retour au repos (`idle_iters:2841`).

## Limites honnêtes

- **Injection clavier impossible sur cette VM** : xdotool type/key, xvkbd,
  XSendEvent — rien ne délivre d'événements clavier X11 (testé aussi sur
  Chrome : aucun texte n'atterrit). Pointer+XTEST marche, clavier non.
  /dev/uinput = root-only. Chaîne clavier vérifiée par `SDL_PushEvent`
  (`--inject`) moins le lien X11→SDL. À re-tester sur machine avec vrai clavier.
- llvmpipe = rendu logiciel : `avg_frame_ms` ≈ 14–30ms n'est PAS la perf GPU —
  c'est la qualification du pipeline. Latency réelle à mesurer sur machine GPU.
- `scroll-into-view` (SDL #13166) non implémenté : le caret n'empêche pas
  l'occlusion par le clavier soft — à faire quand TextField arrive dans une
  zone scrollable. Enfants Android/iOS mesurent le comportement OS.

## API ajoutées (Zig)

- `ui.Scroll`, `ui.dispatchScrollable`, `ui.Semantics/Role`,
  `ui.collectSemantics`, `ui.LazyList` (+`initNode/syncWindow/relayout/invalidate`),
  `ui.TextField` (modèle d'édition, CAP=2048, comp IME).
- `widgets.Button/Toggle/Slider/TextFieldView/divider/label` — pattern
  `var w = W{...}; w.bind(); &w.node`.
- `sdl.zig` : +TEXT_EDITING/_CANDIDATES, SDLK_*, SDL_Rect,
  Start/StopTextInput, TextInputActive, SetTextInputArea, GetClipboardText,
  GetWindowID, PushEvent.
- `host.Event` : `text_editing`, `text_input`, wheel `{dx,dy,x,y}`.
- `Scroll.ensureVisible(r_min, r_max, bottom_inset)` : scroll-into-view minimal
  — la pièce framework du fix #13166 (l'inset IME vient de
  `WindowInsets.ime()` JNI côté Android).
- `ui.Anim` branché au host (dirty consommé avant draw, bug #5) ; démo =
  sélection tuile easing 220ms dans la gallery.
- gallery : `--frames N`, `--secs S`, `--inject "txt"`, JSON stats.

## K2-prep Android (agent enfant, émulateur API36 — mesuré, pas extrapolé)

- **IME = commits-only** : `TEXT_EDITING`/`EDITING_CANDIDATES` jamais émis sur
  Android (SDLInputConnection aplatit en commits). Notre modèle gère la comp
  pour les plateformes qui l'émettent ; Android = insert/commit suffit.
  `SDL_SetTextInputArea` ancre un SDLDummyEdit natif réel (bounds mesurés) ;
  `showSoftInput` rate en race au boot → réémettre au tap du champ.
  Non testé honnêtement : CJK, auto-correction-remplacement.
- **#13166 reproduit, 3 états** : défaut PAN (contenu translaté ~850px, champ
  visible, **zéro event SDL**) ; `ADJUST_RESIZE` dégradé en PAN sur fullscreen ;
  `ADJUST_NOTHING` = champ 100% masqué sans signal. **Seul signal fiable =
  `WindowInsets.ime()` Java** → scroll-into-view à faire côté framework :
  `scroll_needed = field.bottom − (height − ime.bottom)` (mesuré 835px).
- **TalkBack = contrat prouvé** : `AccessibilityNodeProvider` +
  `setImportantForAccessibility(YES)` → TalkBack réel appelle
  `createAccessibilityNodeInfo` (host+3 nœuds), `findFocus`,
  `performAction(ACCESSIBILITY_FOCUS)` ; uiautomator voit les nœuds virtuels
  (labels/classes/bounds exacts) ; TTS en-US réel après fix `tts_default_engine`
  (null par défaut sur l'image). L'arbre plat `collectSemantics` correspond
  exactement à ce contrat. Gestes TalkBack non simulables via `input` injecté.

## K2-prep iOS (agent enfant, sim iPhone 17 / iOS 27.0 — mesuré)

- **IME = commit-only aussi** : TEXT_EDITING jamais émis (confirmé dans la
  source uikit : `textFieldTextDidChange` ignore tant que
  `markedTextRange≠nil`) ; JP romaji = silence total puis commit unique.
  → la composition inline du TextField est un chemin **desktop/web
  uniquement** ; les deux mobiles = insert/commit. Patcher SDL uikit =
  option future.
- **Évitement = l'inverse d'Android** : SDL iOS translate `view.frame.origin.y`
  lui-même pour garder `SetTextInputArea` au-dessus du clavier
  (`updateKeyboard`, source lue) — sur iOS notre seul boulot = bien poser le
  rect. Pas de RESIZED ; `SAFE_AREA_CHANGED` ±34pt = signal booléen, pas la
  hauteur (UIKeyboard hors safe area → `UIKeyboardWillShowNotification` dans
  le shim si un jour on veut la hauteur réelle). `SDL_ScreenKeyboardShown` =
  "session texte", pas visibilité.
- **UIAccessibility = contrat prouvé** : `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER`
  → rootViewController.view → `accessibilityElements` = UIAccessibilityElement
  → VoiceOver dessine le cadre de focus sur les frames ; Accessibility
  Inspector énumère labels/hiérarchie.

## Suite (déjà en vol ou prochain chantier)

- Ponts a11y : arbre sémantique posé → ponts par plateforme (web ARIA →
  TalkBack → iOS → UIA → AT-SPI) — enfants en cours sur les squelettes.
- IME end-to-end mobile : table TEXT_EDITING/TEXT_INPUT + #13166 repro +
  scroll-into-view — agents Android/iOS en cours.
- K1 host macOS/Windows/web — agents en cours.
- P0 restant : plugin officiel + policy réseau (assignment ouvert).

## K1-web : gallery wasm dans le navigateur — PASS

- Build `gallery/build_wasm.sh` : em++ (shim `kx_ctx_create_ganesh_webgl` +
  `kx_target_canvas`→FBO0) + `zig build-obj wasm32-emscripten` + SDL3 statique
  (`SDL3-wasm-build/libSDL3.a`, `-DSDL_SHARED=OFF`) + libs Skia `out/wasm` +
  port emdawnwebgpu → `gallery.js` 521K + `gallery.wasm` 9,5M.
- `host.initCanvasWindow` (nouveau) : SDL_Init+CreateWindow (RESIZABLE, pas de
  flag OPENGL) → shim crée LE contexte WebGL2 sur `#canvas` (SDL ne fait que
  fenêtre+événements ; `kx_present` = flush, le navigateur composite au rAF).
- Boucle : `gallery_init` (fonte @embedFile) + `gallery_step` par rAF ; `step()`
  saute `SDL_GL_SwapWindow` sous wasm, `nowUs` = `emscripten_get_now`.
- **Vérifié visuellement** (Chrome, port 8902) : LazyList + widgets rendus ;
  clic item → sélection violette (~19 frames / 220ms anim) ; molette → défile
  (#0→#15) ; boutons/toggle/TextField focus→caret. Repos = 0 frame.
- Diagnostics exports : `gallery_kick` (force 1 frame), `gallery_target_ok`,
  `gallery_backend`.
- Pièges consignés :
  - **SDL-emscripten probe** : `SDL_CreateWindow` met le canvas à 1×1 puis lit
    `emscripten_get_element_css_size` ; toute CSS sur le canvas (même 1px de
    bordure) gele le buffer à cette taille (3×3 observé). → **zéro CSS sur
    `#canvas`** (bordure sur un wrapper).
  - **Cache navigateur vs `python -m http.server`** : ctrl+shift+r ne
    revalidait pas les sous-ressources (ancien wasm servi pendant des minutes
    → faux symptômes de "rendu noir"). Servir sur un nouveau port à chaque
    rebuild en débogage.

## Pont a11y web (ARIA) — PASS

- Export Zig `gallery_semantics_sync/ptr/len` : `collectSemantics` → JSON
  (rôle→ARIA : button/checkbox/slider/textbox/list/listitem/heading/
  separator) + bounds canvas + focusable/disabled.
- `index.html` : `#a11y` overlay invisible positionné (`opacity:0` = exposé
  aux AT ; `pointer-events:none` = canvas garde les events) — rebuild complet
  à chaque frame dessinée.
- **Vérifié dans Chrome** : 30 éléments (29 + image "Disc") — `heading:"Klaxon Gallery"`,
  `button:"Ajouter 100 pistes"`, `checkbox:"Lignes alternées"`,
  `slider:"Hauteur des pistes"`, `textbox:"Champ de recherche"`, `separator`,
  `list:"Bibliothèque"`, `listitem:"Piste #N — album Demo · 3:0N"` ; rects
  DOM alignés sur le canvas au pixel près (btn@10,70/110w ; li@0,117/900w).
- Coordonnées : bounds buffer-px == CSS-px tant que le canvas n'a aucun CSS
  sizing — si un jour on scale le canvas, diviser par le facteur.
- Limite v1 : rebuild à chaque frame (≤~40 items, cheap) ; focus DOM perdu
  au rebuild — acceptable pour la démo, à remplacer par un diff stable par id
  quand les Nodes porteront un identifiant.

## kx_draw v2 — PASS natif + wasm (visuel)

- Ajouts ABI (header + `kx_skia/src/kx_draw.cpp`, bind Zig `kx.zig`) :
  `kx_path_*` (new/free/reset/move/line/quad/cubic/conic/arc/add_circle/
  add_rrect/close — SkPath immutable au pin → `SkPathBuilder` + snapshot
  par draw), `kx_canvas_draw_path/clip_path/draw_oval/draw_shadow/
  draw_image_nine`, `kx_paint_gradient_radial/sweep`, `stroke_cap/join/
  miter`, `paint_dash`, `image_filter_blur`.
- **Pièges API pin 8643b1d6** : `SkPath` sans mutateurs → tout passe par
  `SkPathBuilder` (`snapshot()` réutilisable, `detach()` consomme) ;
  `SkShaders::SweepGradient(center,start,end,grad,lm)` SANS TileMode ;
  pas d'`addCircle` → `addOval(MakeLTRB)`.
- **Piège critique alphaf** : `SkPaint::getAlphaf` MODULE le shader —
  un paint de base `0x00000000` rend tout shader invisible (symptôme :
  gradient/ombre semblent absents). → paint destiné à porter un shader =
  base alpha opaque (0xFFFFFFFF), la couleur est ignorée, pas l'alpha.
- **Exercice réel** = widget "disc" custom dans la gallery
  (`paint.custom` + `userdata`) : carte rrect + ombre douce, anneau sweep
  violet→cyan 300° cap rond, waveform polyline dashée — screenshots
  natif ET wasm identiques.
- **Unification shim wasm** : `spikes/w0-graphite-wasm/shim/{kx_skia.h,
  kx_draw.cpp,kx_scenes.cpp}` = symlinks vers les canoniques
  (`kx_skia/include|src`). Avant : copies divergées — le header subset
  sans les décls v2 extern "C" faisait émettre les définitions manglées
  C++ → undefined symbols au link. Seul `kx_internal.h` reste
  spécifique par plateforme (internes wasm vs natif).

## Pont a11y macOS (NSAccessibility) — PASS (agent enfant, VM macOS arm64)

- `kx_skia/src/kx_a11y.mm` intégré au canonique + bloc ABI dans `kx_skia.h` :
  `kx_a11y_sync_begin(view, scale)` → `kx_a11y_sync_item(view, id, parent,
  role, label, hint, x,y,w,h, flags)` ×N → `kx_a11y_sync_end(view)`.
  Rebuild-avec-réutilisation clé par `node*` (focus AX préservé) ; end()
  retourne 1 si muté (poste AXLayoutChanged) + AXFocusedUIElementChanged
  sur changement de focus.
- **Hit-test sans swizzle** : `class_addMethod(accessibilityHitTest:)` réussit
  sur SDL_MetalView (verdict 1 — la classe ne l'implémentait pas ; plan B
  swizzle non déclenché, documenté).
- **Piège bounds** : `accessibilityFrameInParentSpace` = relatif au parent AX
  (PAS à la vue) → soustraire l'origine absolue du parent (chaîne remontée) ;
  px physiques ÷ scale puis flip-Y si la vue n'est pas isFlipped.
- **Zig side intégré** : `ui.pushA11y(view, scale, root, alloc)` (Role→
  A11yRole, labels 0-terminés, flags disabled|focusable|focused|selected),
  `host.syncA11y(root, alloc)` gated comptime Apple, install hittest dans
  `initMetalWindow`, `sem_dirty` côté gallery (materialisation/focus/
  sélection → re-push). 0 symbole émis sur Linux (comptime dead).
- **Diffs Windows mergés** : `Backend` enum réaligné sur kx_skia.h (dérive
  réelle — @tagName affichait des noms faux), `--gpu dawn|vulkan|gl`,
  `Args.Iterator.initAllocator` (requis Windows), fonte @embedFile Windows,
  `initDawnWindow(io,title,w,h,.d3d12/.vulkan)` dans host.zig, `--frames N`
  force-dirty (sinon la dirty-gate gèle au repos → jamais de sortie).
- Preuve enfant : System Events voit arbre imbriqué (AXHeading→AXGroup→
  AXButton×2→AXTextField), bounds au point près (750,832 écran).
- Limite : scale=1.00 sur VM (chemin Retina écrit non exercé) ; iOS = même
  forme UIAccessibility non testée.
