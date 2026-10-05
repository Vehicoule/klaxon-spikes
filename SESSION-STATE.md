# État de la session — Klaxon/Vehicoule (2026-10-04)

> Photo au réveil : tout ce qui a été vérifié, construit, et ce qui reste.

## Ce qui existe et fonctionne (vérifié cette session)

| Brique | Path | Statut |
|---|---|---|
| Framework squelette | `klaxon/src/{klaxon,kx,sdl,host,ui,widgets}.zig` | host SDL3 dirty-loop (+`initCanvasWindow` wasm : shim possède le ctx WebGL2, SDL=fenêtre+events), arbre UI flex+hit-test+scroll, **14/14 zig tests** (LazyList, TextField UTF-8/IME, semantics DFS, Scroll.ensureVisible), `ui.Anim` (anim prouvée : 204 frames/220ms → idle 0), `ui.LazyList` virtualisée, `widgets.*` (Button/Toggle/Slider/TextFieldView) |
| API dessin v1 | `kx_skia/{include/kx_skia.h,src/kx_draw.cpp}` | ~40 fns paint/canvas/para/image — portée native **et** wasm (draw_smoke PASS webgl+webgpu) |
| App démo K2 | `gallery/` | 10k items→**11 slots matérialisés**, scroll molette, sélection tuile, TextField focus+insert+caret (preuves visuelles), JSON stats, `--secs/--inject` |
| **Gallery wasm (K1-web)** | `gallery/{build_wasm.sh,index.html}` + `out/wasm/` | **REND dans Chrome** (Ganesh-WebGL2 via shim, SDL=events seulement) : liste+widgets visibles, clic→sélection animée (~19f/220ms), molette→scroll, TextField focus→caret ; repos=0 frame. Exports `gallery_init/step/kick/target_ok/backend`. `gallery.wasm` 9,5M |
| Plugin SDK | `sdk/src/vh.zig` + `sdk/examples/search/` | `pub const vhHandler` + `comptime{_ = vh;}` = zéro boilerplate ; `--max-memory` ferme le gap memory.grow |

⚠️ **`vehicoule/` supprimé sur demande utilisateur** (concentration framework) — le squelette app lecteur et le PluginRuntime WAMR ont été retirés. Le runtime (7/7 selftests) est documenté dans `spikes/p0-runtime/P0-RESULT.md` (spec ADR-0007) — à reconstruire quand le chantier app reprendra. |

## Verdicts clés (détails : VERDICT-SPIKES.md)

- **ADR-0002 confirmée** : Impeller perd ×1.4–×4.3 sur Metal réel (7/9 scènes) et ×2–×30 en software. Skia-only reste.
- **Backend table** : graphite-metal (Apple) / graphite-vulkan (Android≥33) / ganesh-gles (Android<33) / **graphite-dawn-d3d12 (Windows)** / webgpu→webgl2→raster (web).
- **WAMR = runtime plugins** (bytebox troué, zware sans metering).
- **0-frame-au-repos** prouvé Linux+iOS+Android.

## Agents enfants — tous rapportés ✅

- Windows K0 : **4/4 backends** (dawn-D3D12, dawn-Vulkan, ganesh-GLon12, raster) — logiciel (WARP/lavapipe), pipeline qualifié, link Zig Windows OK. Pièges : Dawn=CMake pas GN, `icudtl.dat`, /MT.
- macOS : K0 3/3 + **i0 A/B Impeller-Metal ×1.4–×4.3 contre Skia**.
- iOS : K0 9/9 (Metal ×19 sur s5) + K1 PASS + **i0 iOS-sim Impeller ×2.4–×13 sur les 9 scènes**.
- Android : K0 (graphite-VK floor API33-35) + K1 PASS (lifecycle complet, SDL_AppIterate spin à throttler).

→ **Décision finale : Skia-only confirmée (ADR-0002) sur les 3 fronts ; Impeller éliminé.**

## Prochains chantiers (ordre suggéré)

1. **Ponts a11y** : arbre sémantique posé (`Semantics`+`collectSemantics`) → bridges par plateforme (web ARIA→TalkBack→iOS→UIA→AT-SPI) — enfants sur les squelettes.
2. **IME mobile end-to-end** : modèle d'édition fait. **Android K2-prep rapporté** : TEXT_EDITING jamais émis (commits-only, insert/commit suffit) ; #13166 = seul signal fiable `WindowInsets.ime()` JNI → scroll-into-view framework obligatoire (`field.bottom−(h−ime.bottom)`) ; TalkBack contrat **prouvé** (AccessibilityNodeProvider+setImportantForAccessibility → TalkBack réel appelle createAccessibilityNodeInfo/findFocus/performAction, uiautomator voit les nœuds). iOS encore en vol.
3. **Animation branchée** : `ui.Anim` posé, reste le hook host (dirty tant qu'anim vit).
4. ~~kx_draw v2~~ — **fait** (paths/ombres/gradients radial+sweep/dash/nine-slice — vérifié natif+wasm, widget "disc" dans gallery). Reste conic gradient.
5. ~~K1 web~~ — **fait** (gallery wasm ci-dessus). K1 macOS/Windows — enfants en cours (Windows K1 host+UIA skeleton rapporté ✅, macOS en vol).
6. P0 restant : plugin officiel + policy réseau.
7. (plus tard) Audio engine Zig + PluginRuntime reconstruit.

## Pièges session (pour ne pas les re-tomber)

- Zig 0.17 : `main(init: std.process.Init)`, `init.gpa`, `Environ.getPosix`, `--dep x -Mroot= -Mx=`, pas `@cImport`.
- `zig build-lib` wasm → archive `!<arch>`, PAS wasm → `build-exe -fno-entry -rdynamic`.
- Skia pin 8643b1d6 : `ParagraphBuilder::make` 3 args (+`SkUnicodes::ICU::Make()`), `kNormal_SkBlurStyle` via `SkBlurTypes.h`, raster SkImage→`TextureFromImage` sur graphite, `fTick=nullptr` en wasm.
- Headless Chrome wasm : `--virtual-time-budget` tronque → `/tmp/w0_cdp.py` (CDP 9223, poll `__RESULTS`).
- Screenshot fenêtre : `xdotool getwindowfocus`/`search --name` + `import -window` (wmctrl vide).
- iOS : `skia_enable_graphite=false` au pin, ReleaseSafe casse sim → ReleaseFast.
- Android : graphite-VK floor API33-35, 16KiB = `-Wl,-z,max-page-size=16384`, `SDL_MAIN_USE_CALLBACKS` obligatoire.
- **VM sans clavier injectable** : xdotool type/key, xvkbd, XSendEvent — aucun event clavier ne passe (Chrome inclus). Chaîne texte vérifiée par `SDL_PushEvent` (`--inject` dans gallery).
- **`SDL_EVENT_TEXT_INPUT` n'était pas traduit** dans host.zig → saisie morte partout, trouvé via PushEvent. `type=0x303`.
- **`host.step` consommait `dirty=false` APRÈS `draw()`** → tout re-dirty posé dans draw (anims) était effacé → aucune anim ne tournait. Fix : consommer AVANT draw. Preuve : clic→204 frames pendant anim 220ms→idle.
- **Canvas SDL-emscripten = ZÉRO CSS** : SDL met le canvas à 1×1 puis lit `emscripten_get_element_css_size` ; moindre CSS (1px border) gele le buffer à la taille border-box (3×3). Bordure sur wrapper, jamais sur `#canvas`.
- **Cache navigateur vs `python -m http.server`** : ctrl+shift+r ne revalide pas les sous-ressources → ancien wasm servi pendant des minutes (faux symptômes). Changer de port à chaque rebuild en débogage.
- LazyList : `spacer` Node pour la position absolue, `slot_ptrs` = slots+1 ; scroll content = cursor-(start-shift)-gap.
- zig test/compile : `-Mroot=` syntaxe module, `.{null} **` spacing, `Args.Iterator.init`, `-O fast`.
- **`SkPaint::getAlphaf` module le shader** : paint base 0-alpha → shader invisible (gradient semblait absent). Paint-à-shader = base alpha opaque.
- **Shim wasm réunifié par symlinks** : `spikes/w0-graphite-wasm/shim/{kx_skia.h,kx_draw.cpp,kx_scenes.cpp}` → canoniques `kx_skia/` ; header subset sans décls extern "C" = définitions émises manglées C++ → undefined au link. Seul `kx_internal.h` reste par-plateforme.
- **Merge host Windows fait** : `GpuMode{gl,dawn}`/`DawnVariant`, `initDawnWindow` (comptime-gated → Unsupported hors win), `kx_target_onscreen_dawn(ctx, hwnd, w, h)` + `kx_ctx_create_graphite_dawn_{d3d12,vulkan}` dans l'ABI ; `step(draw,on_event,wait_ms)->{idle,drew,quit}` = WaitEventTimeout au repos (throttle repris du rapport win — tue le spin SDL_AppIterate) ; swap = `gl != null` seulement.
- **Constantes SDL corrigées** (catch enfant mac) : METAL_VIEW_RESIZED=0x208 et PIXEL_SIZE_CHANGED=0x207 étaient sautés → MINIMIZED/MAXIMIZED/RESTORED décalés d'un cran (restored écoutait MOUSE_ENTER). Les 3 ajoutés au chemin resize.
- **Pièges mac K1** (de l'enfant) : binaire CLI nu → fenêtre jamais compositée → `.app` bundle obligatoire ; TEXT_INPUT=0x303 ; 2 simulateurs iOS fantômes (diagnosticd ~150% CPU) faussaient les benchs ×6 → `simctl shutdown all`.
- **K2-prep iOS rapporté** : IME iOS = commit-only aussi (TEXT_EDITING jamais émis — backend uikit n'appelle pas SendEditingText ; composition CJK = silence + TEXT_INPUT chaîne entière). Évitement clavier : SDL translate `view.frame.origin.y` lui-même → notre seul devoir = `SDL_SetTextInputArea` (rect.h==0 → pas d'offset) ; SAFE_AREA_CHANGED ±34pt = booléen, hauteur clavier non exposée (→ UIKeyboardWillShowNotification dans shim si besoin). UIAccessibility prouvé : UIWindow via `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER` + `accessibilityElements=[UIAccessibilityElement]` → VoiceOver dessine les cadres de focus.

## 2026-10-05 — K3-prep (focus + thème + spring) + merge Metal macOS

### Focus navigation (ui.Focus)
- `Node.focused: bool` + `Node.on_key: ?*const fn(n,key,mod) bool` + `Paint.focus_ring: ?*kx.Paint`.
- Anneau dessiné 1px À L'INTÉRIEUR des bounds (survit au clip parent scrollable).
- `ui.Focus{current,set,move(root,dir,alloc)}` : DFS des `semantics.focusable`, wrap aux extrémités.
- `SemItem.focused` exposé (ARIA web : `data-focused` + outline cyan dans index.html).
- sdl.zig : `SDLK_TAB=0x09`, `KMOD_SHIFT=0x3/CTRL=0xC0/ALT=0x300/GUI=0xC00`.
- host.zig : `key_down/key_up` → `{key:u32, mod:u16}` (depuis ev.key.key/.mod).
- widgets.zig : `on_key` partout — Button/Toggle Enter|Space→action ; Slider ←/→ ±5% Home/End min/max ; TextFieldView Backspace/Delete/arrows/Home/End + shift-extend + ctrl+A.
- gallery : `focus.set` sur pointer_down (hit focusable ou blur) ; Tab → `focus.move` ; key sinon routé via `focus.current.on_key`. Test `--key <code>` = PushEvent KEY_DOWN (vérifie toute la chaîne sans X11).
- VÉRIFIÉ VISUELLEMENT : ring cyan 2px visible dans les bounds du bouton après Tab injecté.

### Thème tokens (ui.Theme + ui.theme)
- `Theme{bg,surface,surface2,border,text,text_muted,accent,accent2,selection,focus,danger}` + `.dark`/`.light` presets ; `ui.theme` global mutable (app le remplace au boot).
- gallery 100% tokenisée (paints + paras + clear color) ; `--theme light` flag. `mix(a,b,t)` helper RGBA-lerp.
- Piège : les PARAS hardcodent les couleurs texte — tokeniser les `paraOf` aussi, pas que les fills.

### Spring (ui.Spring)
- Oscillateur stiffness/damping/mass (convention Flutter). `set/to/step(dt_s)/done/dampingRatio`.
- Intégration semi-implicite Euler pas fixe 1/240s, clamp dt≤0.1s, stiffness≤1200.
- gallery : `extent_spring` pilote `list.item_extent` — slider → tuiles qui rebondissent (sous-critique damping=14).
- Tests : critique ne dépasse jamais ; sous-amorti rebondit puis converge. 17/17.

### Merge chemin Metal (enfant macOS → canonique)
- `kx_skia/src/kx_metal.mm` + `kx_a11y.mm` : bridge ObjC verbatim (device/queue/layer configure/nextDrawable/presentDrawable + proto NSAccessibility).
- `kx_skia/src/kx_skia_macos.cpp` : plateforme complète de l'enfant (raster/CGL-GL/graphite-metal/onscreen) + `kx_acquire_surface` hook.
- `kx_target_onscreen_metal(ctx, layer, w, h, scale)` dans l'ABI ; acquire PARESSEUX : `cv()` appelle `kx_acquire_surface` quand `onscreen && !surface` (metal→nextDrawable→WrapBackendTexture ; autres→no-op). Drawable jamais recyclé : present→release.
- sdl.zig : `MetalView` + `SDL_Metal_CreateView/GetLayer/DestroyView` ; `SDL_WINDOW_METAL=0x20000000`, `HIGH_PIXEL_DENSITY=0x2000` existaient déjà (attention doublons).
- host.zig : `GpuMode{.gl,.dawn,.metal}`, `initMetalWindow` gated `.macos or .ios`, `makeMetalTarget` (scale = pw/lw), resize→metal branch, deinit→DestroyView. Present identique à dawn : `presentTarget()` dans draw() — pas de swap SDL.

### En vol
- Rien — tous les enfants ont rapporté. macOS attend peut-être go pour K2-prep (IME/a11y impl réelle).

## K3 — Glass (backdrop blur) — LIVRÉ ✅

- `kx_canvas_save_layer_backdrop(t, x, y, w, h, blur_sigma)` : `SkCanvas::SaveLayerRec` avec `fBackdrop = SkImageFilters::Blur(σ,σ,Decal)` — le mécanisme exact du BackdropFilter de Flutter. ABI dans les 3 couches (h/zig/cpp).
- **PIÈGE SaveLayerRec** : `fBounds` n'est qu'un HINT d'allocation — le filtre backdrop s'applique dans le **clip courant**, pas dans fBounds. Séquence correcte : `save → clip_rrect(bounds) → save_layer_backdrop → dessiner le panneau → restore → restore`. Sans le clip le flou recouvre TOUT le canvas.
- Démo gallery : carte "Glass" flottante par-dessus la LazyList (fill surface 32% + stroke 25% + σ14). Texte des lignes en dessous fondu, bandes visibles — vérifié natif ET wasm (Ganesh-WebGL2).
- **Sync shim wasm** : `kx_flush_target` signature canonique `(kx_ctx*, kx_target*)` + `kx_acquire_surface` → `kx_graphite_canvas_acquire` pour onscreen-webgpu. Les symlinks kx_draw/kx_scenes.cpp compilent contre le `kx_internal.h` du shim wasm (déclarations ajoutées).

### Perf gallery wasm (mesuré)
- `_gallery_kick()` ×200 forcés via console : **0,607 ms/frame moyenne** sur Ganesh-WebGL2 (backend=1) — inclut layout complet + LazyList + widgets + glass card + présent + overhead call JS↔wasm. VM Chrome = probablement SwiftShader/ANGLE (caveat : mesure pipeline, pas GPU réel).

### K3 — Thème complet (dynamic color + system hint) — LIVRÉ ✅

- `Theme` étendu : tokens géométrie (r_sm/r_md/r_lg, gap, pad) + typo (text_sm/md/lg).
- `Theme.fromSeed(seed, dark)` : dynamic color OKLab simplifié (sRGB→OKLab→LCh ; tons pilotent neutres, teinte préserve l'accent, secondaire = teinte +120°). HONNÊTE : pas HCT/CAM16 de Google — proche visuellement, contraste non garanti.
- `--theme auto` (natif : SDL_GetSystemTheme — GNOME/dark hint ; wasm/absent → dark) + `--seed 0xRRGGBB` dans gallery.
- Vérifié visuellement : seed rouge → dark chaud + light rosé cohérents.
- Test ajouté : teinte ±15° préservée, dark/light inversés, roundtrip OKLab ±2/255. **18/18 tests zig.**
- Perf wasm (mesuré console) : **0,607 ms/frame moyenne** Ganesh-WebGL2 (×200 kicks, layout+liste+glass+présent — caveat SwiftShader probable).
- Enfants en vol : macOS = bridge NSAccessibility complet (GO donné, ABI `kx_a11y_sync_*`) ; Windows = parité gallery native dawn-d3d12 (tar canonique envoyé).

### Font stack (multi-familles + fallback couverture) — LIVRÉ ✅

- `kx_fonts_add_dir(f, path)` : scan récursif .ttf/.otf/.ttc trié (POSIX, porté linux+macos+wasm ; profondeur ≤6, erreurs ignorées).
- `kx_fonts_family_index(f, name)` : nom → index (-1 absent).
- `kx_para_push_style_families(p, size, rgba, weight, indices[], count)` : liste ordonnée CSS-like — puis fallback couverture (`onMatchFamilyStyleCharacter` scanne toutes les familles).
- Gallery : `paraOfFamilies("DejaVu Sans, Noto Sans SC")` + `--fonts <dir>` (appliqué post-setup — bug ordre d'init corrigé : args parsés avant host).
- **Vérifié** : titre " 한국어 ñ ελληνικά Привет" — 3 fontes chargées (DejaVu+NotoSC+NotoKR), chaque script résolu automatiquement ; tofu SEULEMENT sur script sans fonte (Hangul avant KR).
- Piège : `kx_fonts_add` (variante macOS) reconstruit la FontCollection à chaque appel → dir-scan O(n²) acceptable en démo ; à amortir plus tard (rebuild au sync_end).
- 18/18 tests zig, wasm rebuild OK.

## P0 restant : PluginRuntime Zig/WAMR 2.4.4 — FAIT (selftest 11/11)

`pluginhost/` : wamr.zig (externs), policy.zig (manifeste permissions
network:/fs:/scan:), natives.zig (vh_host.request/read/release — scan→JSONL
média, fs:read, http→policy+nosys ; registre mutexé single-flight ABI v0.1),
runtime.zig (validation LEB sections : mem min+max ≤1024p — sans max = rejet ;
table ≤65536 ; exports vh_alloc/vh_call ; fuel par appel ; watchdog deadline ;
validate_app_addr + cap 8Mio ; stack 64Kio heap 0).

- Bump WAMR f5f57c0 → 2.4.4 (CVE fast-interp), libwamr.a 597Kio, build.sh
  no-cmake repris de p0-wamr.
- **Correction P0** : terminate sans THREAD_MGR = no-op (pose juste
  l'exception) — le cas du harnais C n'a jamais tourné (gardé NONE). Ajout
  `WASM_ENABLE_THREAD_MGR=1` + thread_manager.c → terminate réel 303ms/300.
- Selftest 11/11 : table-1M→TableLimit, edge-1024p→accepté, fuel 10ms,
  deadline 303ms, claim-100Mio refusé, scanner deny/allow (plugin officiel
  examples/scanner 9,7Kio, op=scan → tracks).
- Pièges : build-lib→archive ar (build-exe requis) ; register_natives trie
  in-place (natives en var) ; écrire instructions_to_execute ne tue pas la
  boucle en cours (compteur copié en local).

## [session — merges enfants + bridge a11y macOS]

- **Windows diffs mergés** (k3-gallery-windows.tar.gz → canonique) :
  kx.zig `Backend` enum réaligné sur kx_skia.h (raster=0..dawn=6 — la
  dérive faisait afficher des noms de backend faux), `--gpu dawn|vulkan|gl`
  + initAllocator-args + fonte embed Windows + `initDawnWindow(...,.d3d12/.vulkan)`
  dans main.zig/setup(), **`--frames N` force-dirty** (bug : dirty-gate gelait
  au repos → jamais de sortie seul ; vérifié exit propre 60 frames 4,2ms llvmpipe).
- **Bridge NSAccessibility intégré** (enfant macOS, PASS) : `kx_a11y.mm`
  canonique + ABI `kx_a11y_sync_begin/item/end` + `kx_a11y_install_hittest`
  (class_addMethod, PAS de swizzle). Zig : `ui.pushA11y` + `host.syncA11y`
  + `sem_dirty` gallery. Piège `frameInParentSpace` = relatif parent AX.
  iOS = même forme UIAccessibility (non testée).
- Enfants : iOS + Android parité gallery en cours.

## pluginhost : http transport + zig test

- `http(s):` implémenté (GET, cap 16Mio via BoundedSink, redirects refusées
  → pas de bypass policy cross-domaine, non-2xx → Err.io, OverCap →
  Err.toobig=-6). Fini le nosys.
- `test.sh` : zig test runtime(6 LEB-gate) + policy(1) + natives(2 http) +
  selftest 11/11 — tout vert. Corpus selftest path résolu depuis ROOT.

## A11Y-BRIDGES.md + fonts lazy + runtime multi-flight

- A11Y-BRIDGES.md = spec gelée des 6 ponts (contrat push begin/item/end,
  map rôles, notifs par plateforme, specs Android/iOS/AT-SPI).
- kx_skia_macos : FontCollection lazy (dirty) comme linux — add_dir N
  fichiers ne rebuild plus N collections.
- pluginhost : policy par instance via wasm_runtime_set_custom_data —
  multi-flight correct, g_policy supprimé. 9 zig tests + 11/11 selftest.

## a11y web : actions (lecture -> action)

- `_gallery_tap(x,y)` exporte down+up via le vrai chemin onEvent (dispatch+
  scrollable+focus). DOM ARIA : click listener + keydown Enter/Espace ->
  tap au centre du node. Prouve : toggle Lignes alternees flippe via
  el.click() console -> rayures visibles. pointer-events:none ne bloque
  PAS le click programmatique ni le focus clavier — les deux couches
  cohabitent (canvas garde la souris, DOM invisible garde l'AT).

## a11y web actions + pluginhost isolation

- gallery_tap(x,y) = tap synthétique via le vrai onEvent → DOM ARIA
  click/Enter/Espace activent les widgets (prouvé : toggle flippe).
- Pending.owner par instance : cross-plugin handle guessing → badh ;
  detach purge les pendings orphelins. 9+11 tests verts.

## wasm a11y : focus retention

- Rebuild-avec-réutilisation par index (ordre DFS stable) remplace le
  textContent='' total : le focus clavier survit aux syncs (prouvé :
  checkbox encore focused après 22 frames + mutation arbre). Même forme
  que kx_a11y.mm keyed-reuse.
- P0 COMPLET : WAMR 2.4.4 (CVE fixé), scanner, policy network, http borné,
  multi-flight instData + isolation handles, 9 zig + 11 selftest.
- Mon lot MILESTONE-PLAN terminé : K2 cœur + K1-web + K3 base + P0 reste.
  En attente : 4 enfants (UIA, AX-actions, parité iOS/Android).

## Retours Android K3-parité (fixes canoniques)

- SLOTS 16→64 (viewport ~2300px couvert) + paras 100% lazy (undefined→null
  splat) + `slots_saturated` dans le JSON — le bug "moitié basse vide" de
  l'agent (16 slots sur 2400px) devient visible au lieu de muet.
- --secs vérifié OK (exit propre + JSON) — le repro Android venait du
  quoting `am start -e`, pas du code.
- Leur provider TalkBack squelette reçoit de VRAIS appels TalkBack
  (createAccessibilityNodeInfo/performAction FOCUS) — contrat validé,
  shim canonique dispatché comme lot suivant.

## a11y actions : ABI canonique gelée

- kx_a11y_set_action_handler + A11yActionCb (kx.zig) + host.
  setA11yActionHandler (trampoline ident→*ui.Node, gated Apple, no-op
  ailleurs tant que les ponts n'exposent pas d'actions) + gallery
  a11yPress → tap au centre. 0 symbole kx_a11y dans le binaire Linux.

## Lot 4 — merge des 4 enfants a11y (final)

Les 4 ponts natifs livrés + harmonisés sur l'ABI canonique
(`void* ident`, `double scale`, retours `int`, `Node.selected` field) :

- **iOS UIAccessibility** : kx_a11y_ios.mm (KXAxElement pool keyed node*,
  traits map, activate/inc/dec → cb). Fixes canoniques rattachés :
  `kx_ios_window_mapped` (UIKit ne poste pas RESIZED au boot → keep-
  producing tant que view.window==nil + 200ms), `translate(ptr_scale)`
  (coords pointeur en POINTS sur Retina — x3 iOS, fixe aussi macOS),
  SetTextInputArea ÷scale (coordonnées point, pas px).
- **macOS NSAccessibility v2** : KxA11yElement (kxIdent/kxState/kxActions),
  Perform{Press,Increment,Decrement} → handler canonique.
- **Windows UIA** : kx_a11y_win.cpp complet (Simple+Fragment+FragmentRoot+
  SelectionItemPattern, SetWindowLongPtr subclass). Pièges documentés :
  mutex relâché avant UiaReturnRawElementProvider (self-deadlock sinon),
  HWND fragment-root only (merge layer injecte la titlebar dans chaque
  nœud sinon). 37 nœuds vérifés VisualUIAVerifyNative. Aucun action_cb
  (Select()→clic WM_LBUTTON synthétique = même règle "vrai input").
- **Android TalkBack** : KxA11yProvider.java (push-fed statiques,
  map pointer→jint nodeId), KxSurface, SDLActivity modifiée,
  kx_gallery_glue.cpp (sync canonique + probes WindowInsets + SDL_main
  → kx_gallery_main). ACTION_CLICK → marshal thread SDL (a11y_pending_*).

Wiring zig harmonisé : host.syncA11y gère macOS/iOS (view), Android
(view ignorée → provider JNI), Windows (hwnd — désormais toujours
peuplé, GL mode inclus) ; setA11yActionHandler étendu à Android ;
initGlWindow popule hwnd sur Windows.

Fixes frame : ES3+stencil+fullscreen Android (initGlWindow branche),
gp_mask_egl=!is_android (Android = vrai EGL, ne pas masquer les
symboles egl*), SDL_GetWindowFlags+SHOWN+FULLSCREEN dans sdl.zig.

IME #13166 câblé (framework) : probes kx_ime_bottom/kx_ime_visible/
kx_view_bottom (JNI) + computeImeShift → layout.y = -ime_shift
(Scroll.ensureVisible existait déjà ; le lift global couvre le cas
fullscreen où le champ n'est pas dans une liste). Champ `Node.selected`
+ filtre décoratif (label vide + !focusable + generic → skip).
kx_gallery_main export (Init synthétique) pour l'entrée SDLActivity.

Vérifié : 18/18 zig tests, build+run natif (60 frames, 3.8ms llvmpipe).
Artefacts : platform/{windows,android}/ + docs/K2-A11Y-macos.md.
AT-SPI = seul pont restant (design écrit, reporté — pas d'AT consumer).

## Lot 5 — vérif canonique enfants (UIA-2 Windows + K5 iOS)

**Windows (UIA-2, 3/3 PASS)** : rebuild canonique OK ; action handler UIA
complet — `IInvokeProvider` (roles 1/2/6)→cb(0), `IRangeValueProvider`
(slider)→SetValue→cb(1|2 par signe delta), Select→cb avec WM_LBUTTON en
fallback ; cb appelé HORS g_mtx ; gate setA11yActionHandler étendu à
`.windows` via `self.hwnd` ; `view=null` accepté (global, applique aux
bridges). Vrai clavier prouvé : SendInput KEYEVENTF_UNICODE → SDL →
TEXT_INPUT → field.insert ("alut kx" affiché — le 's' mangé par la race
clic→focus→StartTextInput, consigné honnête). Slider AT : action 1→focusSet
+SDLK_RIGHT→anneau focus visible (a11yPressRun mappe 1|2→flèches).

**iOS (K5, tout PASS)** : canonique rebuild + les 3 fixes revérifiés
(window-mapped→rendu au boot, ptr_scale→tap réel→Piste #30,
SetTextInputArea ÷3.0 instrumenté). A11y e2e : 97 éléments, traits
corrects, activate→a11yPress→tap→onAdd100→items:10100 (preuve chiffrée).
2 retouches mergées : `dupeZ`→`dupeSentinel(u8,s,0)` (API renommée zig
0.17 — BUG LATENT canonique : masqué par lazy-compile, pushA11y gated
non-referenced sur Linux) + `kx_skia_ios.cpp` platform file (manquait
dans canon4 — copié dans kx_skia/src/, bloc fonts canonique porté).

Pièges iOS consignés : attachment→download_attachment (curl=401), `--frames`
peut sortir avant les timers a11y (`--frames 400 --a11y-at 2500`), champ
sous status bar = zone morte (`--inject` contourne), dump périodique
réactive le 1er Button à chaque tir.

Platform files canoniques complétés : `kx_skia_win.cpp` (dawn swapchain
par HWND, kx_dawn_surface* dans kx_target, kx_target_canvas_ready decl)
+ `kx_skia_ios.cpp` — les 4 fichiers platform présents.

En attente : macOS (AX actions e2e + marked-text IME), Android (rebuild
canonique + TalkBack + vérif réelle ime_shift).

## P0 — bouclé (scan récursif + fixture reproductible)

- `buildScan` est maintenant récursif (borne SCAN_MAX_DEPTH=8, dossier
  illisible = skip de branche) — un scanner musical non-récursif ne vaut
  rien (bibliothèque = artiste/album/piste). Le bug était masqué :
  fixture plate = /tmp effacé au reboot.
- Fixture déplacée dans `pluginhost/fixtures/music/` (rock/track-one.mp3
  + track-two.flac imbriqués → prouve la récursion) ; test.sh l'utilise
  par défaut, `FIXTURE=<dir>` surcharge.
- **P0 terminé** : scanner officiel + policy manifest→allowlist
  (deny/allow testés) + WAMR 2.4.4 + host standalone + 9 zig + 11/11
  selftest verts.

## Vérification canonique enfants (canon4→canon5) — TOUTES PASS
- **Windows UIA-2** : IInvokeProvider/IRangeValueProvider/Select → cb canonique ;
  vrai clavier SendInput→TEXT_INPUT prouvé ("salut"→"alut", race focus consignée).
- **iOS K5** : canonique rebuild, a11y e2e (activate→onAdd100→10100), 97 éléments.
- **macOS K3** : AX actions e2e + marked-text IME réel ("書かな" commit via
  text_editing inline + candidats) ; font-fallback (DejaVu tofu → --fonts Hiragino).
  Fixes mergés : recorder+stub GL dans kx_skia_macos.cpp, dumpEl/activate_ident
  dans kx_a11y.mm, embed font macOS, branche initMetalWindow macOS gallery.
- **Android K4** : canonique pur build+run (ganesh-GLES SwiftShader) ;
  TalkBack 87 nœuds, performAction→Piste#1 selected ; **ime_shift=873px stable
  mesuré, champ visible au-dessus du clavier** (#13166 fix prouvé end-to-end).
  Bugs canoniques corrigés par l'enfant → mergés : KxProbe.java manquait au tar,
  signe computeImeShift (+shift, oscillation 0↔873), veille jamais pompée
  (dirty forcé pendant ime_watch_until), sem_dirty sur mutation shift,
  font embed is_android, stats JSON→fichier (stderr invisible logcat),
  --bottom-field (champ toolbar jamais couvert sinon).
- Latent bug zig 0.17 trouvé par vérif réelle : `dupeZ`→`dupeSentinel` (lazy
  compile masquait — pushA11y non référencé sur Linux).
- Platform files complètes : kx_skia_{linux,macos,win,ios,android}.cpp.

## [session — AT-SPI Linux bridge DONE + gallery publique]

- **6/6 ponts a11y LIVE** : AT-SPI implémenté (`kx_skia/src/kx_a11y_linux.cpp`
  ~850 lignes, sd-bus dlopen + ABI déclarée à la main — zéro dep build).
  Vérifié contre un vrai at-spi2-registryd (userspace, bus privé) :
  Embed→tree(7 top + 11 items)→rôles/noms/extents/états exacts→DoAction→
  SELECTED réellement allumé (mutation bout-en-bout).
- **Pièges ABI mesurés** : sd_bus_set_bus_client obligatoire avant start
  (sinon ECONNRESET) ; vtable START exige element_size+features+
  vtable_format_reference (dlsym du global exporté) sinon EINVAL silencieux ;
  sd_bus_get_unique_name = out-param ; sd_bus_error_free pour les erreurs.
  Tout consigné dans A11Y-BRIDGES.md.
- **host.zig** : branches Linux ajoutées (syncA11y → pushA11y(null,..),
  setA11yActionHandler → handler global, pump `kx_a11y_pump` par step,
  comptime-gated).
- **Gallery wasm publique** : https://dist-wrnlmhjl.devinapps.com (deployé).
- Fixtures /tmp effacées au reboot : /tmp/atspi-root + bus privé = harnais
  de test éphémère ; le code canonique n'a aucune dépendance /tmp.

## [session — V0 lecteur musical : chaîne complète vérifiée]

- **player/** = V0 local music player sur la framework : scan via le vrai
  plugin sandboxé (scanner.wasm sous WAMR + policy scan:<dir>, thread
  dédié) → LazyList bibliothèque → transport (|< II >| + seek + volume)
  → décodage dr_libs vendored (mp3/flac/wav → f32 interleaved) →
  SDL_OpenAudioDeviceStream push-feed (~0.4s en file).
- **Vérifié headless** (X TigerVNC + SDL_AUDIODRIVER=dummy) : 5 pistes
  trouvées par le plugin (grant correct), decode→stream→fed=352800
  frames=8.0s exacts @44.1k, pos 4.0s, ended→nextTrack (track1→track2
  vu à l'écran), fin de file = park (pas de boucle). Screenshot UI :
  header now-playing + seek qui suit la position + liste surlignée.
- **Bugs réels trouvés par le test** :
  - natives.zig hostRelease : use-after-remove — `e` pointe dans la map,
    `g_pending.remove(h)` invalide puis `free(e.buf)` lisait de la mémoire
    morte → GPF (crash n'apparaissait pas en selftest). Fix : copier buf
    avant remove. Canonique pluginhost corrigé.
  - SDL audio : OpenAudioDeviceStream échouait sans SDL_InitSubSystem
    (host SDL_Init ne couvrait pas audio) → cycle instantané de pistes.
  - decode_path jamais libéré → leak storm sur la boucle nextTrack.
  - nextTrack sur la dernière piste = rejoue infini → park à la fin.
- Honnête : sortie audible NON vérifiable sur cette VM (pas de carte
  son) — le driver dummy prouve queue/resample/push, pas l'écoute.
- Formats : mp3/flac/wav décodés ; ogg/opus/m4a listés par le scanner
  mais kxdec_open retourne null honnêtement (decode_failed → statusbar).
- Args test : --dir --plugin --autoplay --secs N --frames N --theme.

## [session — Clôture : alignement V0 (ADR-0005 amendée) + gates K3]

- **player/ → vehicoule/** renommé (app conforme au nommage docs).
- **Audio : SDL_AudioStream conservé** — ADR-0005 amendée v16 : miniaudio
  retiré (doublon device/mix vs SDL3 déjà embarqué). Ne PAS revendor.
- **Décodeurs vendored pur-C** (portable Android/iOS) : stb_vorbis
  (.ogg/.oga) + opusfile+libopus+libogg (.opus, sortie stéréo f32@48k
  native). decoder.c dispatch par ext ; m4a/aac/wma → refuse honnête
  (décodeur OS par plateforme = lot ultérieur). .oga ajouté à MEDIA_EXTS.
- **API domaine V0 typée µs** (spec V19) dans vehicoule/src/media/ :
  source.zig = MediaSource union {local_file|http(origine+credential_ref+
  validators+caps)} + Capabilities{seekable,offline_ok,resumable} +
  formatForPath ; events.zig = MediaEvent{state|position µs|capabilities|
  err} + MediaCommand{play|pause|seek:µs|stop} + JobId + Subscriber ;
  queue.zig = Queue items{source,title}+index (park fin de file).
  Engine expose load(MediaSource)/command/subscribe — events poussés
  (state/caps/err), positionUs/durationUs/seekUs en µs. HTTP →
  fail(unsupported_source) honnête, seek refusé si !caps.seekable.
- **Vérifié** : 8 pistes mixtes scannées par le plugin wasm ; ogg ET opus
  décodent (fed>0, playing) en runs isolés + refactor domaine intact.
- **Gates K3 = gates/run.sh + thresholds.json** : résultats JSON forme
  ADR-0008 (sha/driver/scene/status/measurements/reason), exit 1 si FAIL.
  6 gates : scroll-p99<16.7, materializations>0, cold médiane-3<200ms
  llvmpipe (150ms = seuil hw V1, documenté), idle≈0-frame, vehicoule
  fed>0, vehicoule-ui-p99<16.7. Mesures : p99 scroll ~10ms, cold ~110ms
  médiane, idle 2 frames, vehicoule p99 ~4-6ms — 4 runs verts de suite.
- **p99 instrumenté** dans host.Stats (ring 2048 + p99FrameMs) ; JSON
  stats des 2 apps étendus (backend/driver/first_frame/p99).
- **Bugs trouvés par les gates** : plugin_path relatif au cwd → tracks:0
  hors vehicoule/ (fix : résolution /proc/self/exe → ../../pluginhost,
  openFileAbsolute) ; MEDIA_EXTS sans .oga.
- **gallery --wheel N** : injection molette PushEvent espacée 40ms →
  vraie scène scroll pour la gate p99 (matérialisations ~230 prouvées).
- En vol : enfant Android re-dispatché = MediaSession Android (dernier
  item spec V0) — notifié à son retour pour merge.

## [suite clôture — décodeur OS ffmpeg : tout format local joue]

- decoder.c gagne KXD_FFMPEG : fork/exec ffmpeg (`-f f32le -ac 2 -ar
  48000 pipe:1`, stderr→/dev/null) pour aac/m4a/wma et ext inconnues —
  pas de shell, refus honnête si ffmpeg absent/erreur (exit!=0→fail).
  ADR-0005 « AAC/ALAC via décodeur OS (FFmpeg Linux) » honorée.
- audio.zig : pré-gate de format supprimée — vendored en primaire,
  ffmpeg en fallback ; kxdec_open NULL → decode_failed honnête.
- Vérifié isolé : .m4a(AAC) fed=24576 playing, .wma fed=24576 playing.
- **Critère de sortie Clôture V0 atteint : tout format listé par le
  scanner joue** (mp3/flac/wav/ogg/oga/opus natif + aac/m4a/wma via OS).
- Gates re-run après ffmpeg path : 6/6 PASS.

## [curation repo propre — plan proposé (pas encore poussé)]

IN (source seule) : klaxon/src, kx_skia/{include,src}, platform/{android,windows},
vehicoule/{main.zig,audio.zig,decoder.c,build.sh,src,vendor,music-test,music-test-compressed},
pluginhost/{src,examples,fixtures,build.sh,test.sh,RUNTIME-RESULT.md},
sdk/{src,examples}, gallery/{main.zig,index.html,build*.sh,DejaVuSans.ttf,docs,k4-ios.json},
gates/{run.sh,thresholds.json}, docs/, *.md racine (A11Y/MILESTONE/VERDICT/SESSION-STATE/K2).
OUT : spikes/ (7G artefacts build — verdicts déjà dans VERDICT-SPIKES.md),
*/out/, gallery/dist/, results/ (dumps bench — chiffres dans SESSION-STATE),
player/ (résidu renommage — supprimé).

## [suite — MediaEvent.position émis]

- Engine émet `.position{position_us,duration_us}` throttlé 250ms dans
  feed() + une émission à 0 au start (spec V19 honorée — l'union
  existait mais ne tirait jamais). main.zig était déjà 100% sur
  load/command/subscribe. Vérif : playing + fed>0, gates 6/6 PASS.

## [curation + baseline poussée]

- Amends user appliqués : verdicts *.md dedans, `spikes/src/` = repro
  curée (74 fichiers : apps+shims+scripts+resultats JSON par spike ;
  deps vendored/builds/fonts/wasm exclus — repro via pins documentés),
  `.gitignore` encode la politique (out/dist/build/results/caches/
  *.wasm + exception spikes/src/**/results).
- Baseline commit b4f61c5 : 431 fichiers / ~13 Mo → poussée sur `main`
  du repo Vehicoule/Klaxon (vide → commit initial direct, pas de PR).
  `devin/baseline-import` existe aussi = HEAD par défaut du remote
  (poussée en premier) — à basculer sur main dans les settings GitHub.
- Sanity secrets : aucun fichier sensible stagé (hits = identifiants code).

## [K5 MediaSession Android mergé — clôture V0 COMPLÈTE]

- Enfant Android : TransportControls → MediaSession.Callback → JNI →
  pending → drain SDL → engine prouvé bout-en-bout (media_cmds:7 ; play/
  pause/next/prev/seek ms→µs/stop). Réserve documentée : keyevent
  media-button non routé sans MediaButtonReceiver+requestAudioFocus
  (noté prod) ; debugTransport via extras = même chemin callback.
- Mergé canonique : KxMediaSession.java (install/release + publishState/
  publishMeta + debugSeek/debugTransport), SDLActivity (install onCreate,
  extras debug kx_media_seek/kx_media_tc, release onDestroy), bloc
  kx_media_* dans kx_gallery_glue.cpp (cb + FindClass publish).
- vehicoule/main.zig : handler pending atomique drainé tick() →
  command(.play/.pause/.seek µs/.stop) + next/prevTrack ; publishState
  sur events state/position ; publishMeta à chaque piste playing ;
  stats JSON +media_cmds. Tout gaté comptime is_android (zéro émis
  Linux — build+run vérifiés, gates 6/6 PASS).
- **Clôture bouclée** : tout format local joue (vendored+ffmpeg OS),
  gates tournent, API domaine µs, MediaSession Android branché. V1 peut
  démarrer : APK signé sideload, devices (proxy honnête vs cloud —
  décision user requise), nightly RSS/cold/pacing.

## [V1 amorcé — RSS nightly + APK en vol]

- host.Stats.peakRssKb() via getrusage(maxrss) ; +peak_rss_mb dans les
  stats JSON gallery/vehicoule ; gates provisoires rss : vehicoule<200Mo
  (mesuré ~122), gallery<220 (~133) — proxy llvmpipe, budget réel
  recalibré sur device de référence V1. Gates 8/8 PASS.
- Enfant Android dispatché : APK Vehicoule (vraie app) buildé + signé
  keystore debug local (sideload), MediaSession end-to-end sur piste
  réelle. Trou signalé : scanner.wasm sous WAMR-Android → fallback
  fixtures embarquées + item V1 explicite si chantier séparé.
- PENDING user : décision devices physiques (proxy honnête vs Firebase
  Test Lab/équivalent = approbation + coût) ; flip default branch
  devin/baseline-import → main.

## [V1 poche — APK Vehicoule sideload PROUVÉ + mergé canonique]

- Enfant Android : APK de la VRAIE app buildé/signé/installé/joue sur
  émulateur API36 (GLES SwiftShader + AudioTrack émulé, drivers consignés,
  aucune extrapolation). 8 pistes fixtures jouées en file auto
  (ogg→flac→oga→opus→mp3→wav×2) — les 5 décodeurs vendored compilent
  NDK sans patch. fed:270336.
- MediaSession e2e sur la vraie app : pause/play/seek(2000ms)/skipNext →
  engine.command() (media_cmds:4) ; meta republiée par piste ; bonus
  AVRCP Bluetooth consomme la session (même contrat lockscreen/notif).
- Signature : keystore keytool local → apksigner → adb install OK.
  Cert SHA-256 0301d4a0…f193b1a87. Keystore privé JAMAIS livré.
- Mergé canonique : kx_vehicoule_main export (std.process.Init synthétique),
  scanNative() (JSON identique scanner.wasm — WAMR-NDK documenté trou V1),
  font @embedFile DejaVuSans.ttf (repo vehicoule/), stats→files/vehicoule.json,
  teardown+scanWorker gatés comptime !is_android, KX_MAIN_SYM dans glue,
  CMakeLists-vehicoule.txt + build_veh.sh (staging documenté).
- Bugs réels absorbés : bufPrintZ n'existe PAS en zig 0.17 (lazy-compile
  le masquait — gated android) → bufPrintSentinel ; p99 conservé au
  canonique (le pin enfant était antérieur).
- **Vérif croisée clé** : zig build-obj -target x86_64-linux-android.31
  compile le chemin android complet en local — 0 erreur. Le lazy-compile
  ne peut plus masquer les branches comptime-android.
- Gates re-run post-merge : 8/8 PASS. APK livré hors repo
  (work/deliverables/vehicoule-v1.apk, 30 Mio).

## [V1 nightly pacing instrumenté]

- host.Stats : interval_ms_ring + p99IntervalMs() — intervalle
  présent→présent (jitter pacing v13). Émis `pacing_p99_ms` dans les
  stats JSON des 2 apps. Pas de gate seuil encore : métrique mesurée
  d'abord (llvmpipe ~2,5ms back-to-back — pacing réel = vsync device).
- Nightly véritable : nécessite un scheduler externe (cron VM meurt au
  sleep ; automation Devin = VM fraîche sans deps) — branché quand CI/
  cloud devices décidés. Le harness run.sh est la brique réutilisable.

## [V1-iOS mergé — vraie app sur simulateur + MediaSession iOS]

- Enfant iOS : Vehicoule joue en sim (iPhone 17 / iOS 26.5, graphite-metal
  Apple sim GPU). tracks:8, fed:53248, pos temps réel, enchaînement
  auto prouvé 2 runs. avg 8.76ms (feed audio continu), cold 601ms.
- MediaSession iOS livrée : platform/ios/kx_media_ios.mm — miroir exact
  du contrat Android (actions 0-5) sur MPNowPlayingInfoCenter +
  MPRemoteCommandCenter ; nowplaying.json réellement publié
  (title/duration/elapsed/rate) ; chaîne remote-command prouvée selftest
  (emit(2) → media_cmds:1 → nextTrack).
- is_mobile = android∨ios : tous les gates étendus (MediaSession,
  scanNative, font embed, stats fichier, kx_vehicoule_main, teardown).
- Décodeurs : gate KXD_NO_FFMPEG iOS dans decoder.c (refus honnête
  m4a/aac/wma — fork/exec impossible).
- Bugs réels absorbés : initGlWindow→NoKx iOS (dispatch initMetalWindow),
  std.os.linux.nanosleep→io.sleep, env SIMCTL_CHILD_* (pas d'argv),
  SDL_GetBasePath→bundle music-test/, stats→Documents/vehicoule.json,
  main→SDL_RunApp forward.
- ru_maxrss Apple = BYTES corrigé (peakRssKb div 1024 sur Darwin).
- Build script repo : platform/ios/build_vehicoule_ios.sh (zig
  a64-ios-sim + décodeurs + bundle .app + UIBackgroundModes audio).
- FAIL env honnête consigné : zéro device audio hôte → coreaudio
  "Device not found" ; l'app dégrade proprement (open failed→ended→next).
  Audio réel vérifiable device/hôte-avec-sortie uniquement.

## 2026-10-04 — V1 : device.sh + watch items v17
- `gates/device.sh` + `platform/android/docs/device-measure.md` : mesure
  les mêmes gates ADR-0008 sur device adb réel (install APK, push fixtures
  en sandbox, `am start -e kx_args`, récup stats JSON, eval
  thresholds.json). `driver` consigne `device:<modèle> sdk<N>` ; émulateur
  détecté et marqué (SKIPPED si --strict-hw) — jamais extrapolé.
- Watch items v17 consignés : `scanNative` borné jusqu'à WAMR-NDK (V2 =
  les plugins reprennent) ; contrat MediaSession généralisable (MPRIS =
  3ᵉ implémentation à V6, même `media_cmds`).

## 2026-10-05 — V1 : gates sim-iOS Metal (proxy honnête) + gate taille APK
Mesures réelles iPhone 17 / iOS 26.5, driver `graphite-metal(Apple iOS
simulator GPU)` — **proxy Metal, non extrapolé hardware** (enfant iOS).

| scène | vehicoule | gallery |
|---|---|---|
| avg_frame_ms | 9.18 | 14.49 |
| p99_ms | 23.75 | 24.47 |
| pacing_p99_ms | 35.80 | 24.56 |
| first_frame (médiane×3) | 12.61 | 19.72 |
| idle | ~4.8/s warm-up | 5f/1002 iters |
| peak_rss_mb | 314.3 | 311.6 |

Verdicts gates (provisoires llvmpipe, rappel : non calibrées device) :
cold<200 PASS · idle≤6 PASS · p99<16.7 FAIL-proxy (spikes PSO compile +
drawable sim) · rss<200 FAIL (~310 Mo les deux — vs 122/133 llvmpipe ;
signature à analyser : Retina @3x + Metal driver + overhead sim).

Appris : simctl install peut no-op silencieusement (vieux binaire mesuré)
— vérifier par `strings` ; KX_MUSIC_DIR est le vrai nom env ; APFS peut
retarder la visibilité du .o (retry nm ×5 mergé dans
build_vehicoule_ios.sh + fix ROOT ../..).

Gate `vehicoule-apk-size` ajoutée (<25 Mo provisoire ; cible ~9-11 Mo —
BUILD-PROFILE.md) mesurée par device.sh.

## 2026-10-05 — V1 : APK dual-ABI arm64+x86 signé (enfant Android)
- `vehicoule-v1-arm64.apk` 29,4 Mo, sdk31, native-code arm64-v8a+x86_64,
  même cert `0301d4a0…`. libmain arm64 **8,59 Mo** (gc-sections→icf→RS+Oz).
- e2e APK cold **≈33 s** : zig 3,4 + décodeurs 5,7 + link 0,2 + gradle 29,1 + signe 0,37.
- Merge canonique : host.zig AT-SPI `abi!=.android` (os.tag=.linux est vrai
  sur Android — cassait les 2 ABI), KXD_NO_FFMPEG étendu `__ANDROID__`
  (SELinux execve API29+), CMakeLists per-ABI -Oz gc/icf, build_veh 2 ABI.
- arm64 = NON EXÉCUTÉ (pas d'image système arm64 hôte x86) ; x86_64 exécuté
  sur kx36 : install signé, autoplay fed:208896, media_cmds:2.
- Pièges consignés : assembleDebug sans -PBUILD_WITH_CMAKE = APK sans
  libmain ; abiFilters exige purge intermediates/cxx+.cxx.
- Gates locales : 8 PASS + apk-size SKIPPED (évaluée par device.sh).
