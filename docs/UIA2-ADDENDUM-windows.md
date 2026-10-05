# UIA-2 Windows — addendum (actions + clavier réel)

Suite de `UIA-BRIDGE-windows.md`. Lot : rebuild canonique + handler
d'action + vrai clavier. Verdict : **3/3 PASS** (voir `uia2-verif.json`).

## Étapes

| étape | vérif | résultat |
|---|---|---|
| 1. rebuild canonique | `uia_dump` ≥30 nœuds, aid kx-N | **36 nœuds**, kx-0…kx-30, graft natif |
| 2. action handler | `Select("Piste #3")` → tap réel | `sel=1` + highlight violet visible |
| 2. invoke | `Invoke("+100 pistes")` | hr S_OK, cb dispatché |
| 2. rangevalue | `SetValue("Hauteur",80)` | action 1 → focus+SDLK_RIGHT → anneau focus slider |
| 3. clavier réel | SendInput type+backspace | "alut kx|" puis "alut|" à l'écran |

## Ce qui a été ajouté (patch-kx_a11y_win_cpp.patch)

- `kx_a11y_set_action_handler(view, cb, ctx)` : view=HWND → bridge de la
  fenêtre ; view=null → handler global appliqué aux bridges existants ET
  futurs (même sémantique que le `null` Android).
- `IInvokeProvider` sur roles {button=1, checkbox=2, listitem=6} →
  `Invoke()` → `cb(ctx, ident, 0)`.
- `IRangeValueProvider` sur role==3 (slider) → `SetValue(v)` →
  `cb(ctx, ident, delta>=0 ? 1 : 2)` ; Value/Min0/Max100/Small1/Large10/
  IsReadOnly=false avec état interne par nœud (la valeur zig vit côté zig).
- `Select()` appelle `cb(ctx, ident, 0)` ; le `PostMessage WM_LBUTTON`
  synthétique n'est conservé qu'en fallback si aucun handler enregistré.
- `dispatchAction` appelle le cb **hors `g_mtx`** (même principe que le fix
  WM_GETOBJECT — le trampoline zig peut réentrer).
- Stubs honnêtes : `kx_a11y_clear` (drop refs), `kx_a11y_install_hittest`
  (no-op — ElementProviderFromPoint suffit), `kx_a11y_debug_dump` (stderr),
  `kx_a11y_activate_ident` (cb direct action 0).

## Zig (à merger)

- `host.zig` : gate `setA11yActionHandler` étendu à `.windows` — utilise
  `self.hwnd` (view absente sous Windows).
- `main.zig` : `a11yPressRun` — action 1|2 → `focusSet(node)` + replay
  `SDLK_RIGHT`/`SDLK_LEFT` (vrai input path clavier, pas de set direct).
- `ui.zig` : `alloc.dupeZ` → `alloc.dupeSentinel(u8, s, 0)` — dupeZ n'existe
  plus en Zig 0.17 (le canonique a été écrit pour un autre std ?).
- `kx_a11y_win.cpp` : `sync_item` retourne `0` sur le chemin normal
  (retapage int incomplet — C4715 corrigé).
- `kx_internal.h` : champ `kx_dawn_surface* dawn` dans `kx_target` +
  decl `kx_target_canvas_ready` (requis par le platform file Windows).
- `kx_skia.cpp` (platform file, shim/) : `kx_fonts_add_dir` +
  `kx_fonts_family_index` (miroir linux, Win32 FindFirstFile) + stubs
  `kx_metal_acquire/present`.

## Outils de vérif ajoutés

- `uia/uia_action.exe` : `--select|--invoke|--range|--focus <name-substr>`
  — cherche dans le RawView, exécute le pattern, sort JSON.
- `uia/send_keys.exe` : `--fg|--click x y|--type s|--key vk [n]` —
  SendInput réel (OS-level, pas de PostMessage).
- `uia/uia_dump.exe` : ajout colonne `aid="kx-N"` (AutomationId).

## Piège noté

Premier caractère frappé juste après un clic de focus dans le champ peut
être absorbé (race clic → focusSet → SDL_StartTextInput vs. keystroke) :
8 chars envoyés, "alut kx" affiché. Comportement honnête consigné —
en prod le lecteur d'écran tape après que le focus a déjà été pris.
