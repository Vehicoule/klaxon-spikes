# MILESTONE-PLAN — Klaxon (framework), révision post-spikes

> Plan par lot issu du ROADMAP v20, réécrit après les spikes mesurés (2026-10-04).
> Découpage pensé pour 4 agents enfants + moi-même (Linux) en parallèle.

## Actualités vérifiées (impactent les pins/choix)

| Sujet | État | Impact |
|---|---|---|
| Zig **0.17.0 release** | sorti le 2026-10-02 (hier) | on est déjà dessus ; keep pin |
| SDL3 | latest = **3.2.28** (2025-12) ; notre pin 3.2.16 | bump candidat — vérifier changelog avant, pas de raison urgente de bouger un pin qui passe |
| WAMR | latest = **2.4.4** (2025-11) — CVE-2025-64704 + CVE-2025-64713 touchent fast-interp (notre mode !) | **bump obligatoire** au prochain build runtime |
| Skia Graphite | lancé en prod dans Chrome macOS (juil. 2025) ; Google prévoit de **supprimer Ganesh** à terme | valide ADR-0002 ; mais "Ganesh sera retiré" = notre pin 8643b1d6 doit être revisité avant la prochaine mise à jour Skia |
| SDL3 IME | `SDL_StartTextInputWithProperties` (type/autocorrect/multiline/Android InputType) + `SDL_SetTextInputArea` ; **issue #13166 : Android n'évite pas le clavier** (le champ peut être masqué), iOS décale toute la fenêtre | K2 doit implémenter la remontée du champ nous-mêmes côté Android |
| M3 Expressive | motion = **springs physiques**, bibliothèque 35 shapes, dynamic color | K3 : animer par ressorts pas par tweens fixes |

## Logique vérifiée (claims du corpus vs mesures)

- Claim v19 "Impeller échecs GLES" → **faux** (rendu correct, juste lent). Corrigé.
- Claim "Graphite partout" → vrai sauf Android <33 et sans-GPU → table 3 niveaux confirmée.
- Claim "SDL suffit au host" → vrai pour fenêtre/lifecycle/GL ; **faux pour a11y** : SDL3 n'a **aucune** API d'accessibilité → ponts plateforme obligatoires (voir K2).
- Claim "IME via SDL suffit" → partiel : SDL expose les events mais pas la politique d'évitement du clavier Android → code métier requis.

---

## K1 — Hôte SDL3 (reste : macOS, Windows, web)

**Objectif lot** : host SDL3 toutes plateformes + lifecycle + SurfaceId/génération + scheduler d'invalidation.

**État** : Linux ✅ (host.zig dirty-loop, 0-frame repos) · iOS ✅ · Android ✅. **Reste : macOS, Windows, web (emscripten SDL3).**

**Étapes** :
1. macOS : host.zig — SDL window + `kx_ctx_graphite_metal` via `SDL_Metal_CreateView` (layer CAMetalLayer), dirty-loop, resize/rotate/bg/fg. Mêmes compteurs lifecycle que K1-iOS.
2. Windows : host.zig — SDL window + Graphite-Dawn-D3D12 (dawn natif dispo grâce au build K0-win CMake) ; fallback Ganesh-GL/WGL.
3. Web : SDL3 compilé emscripten + cible `kx_ctx_graphite_webgpu`/`ganesh_webgl` déjà prouvée en W0 — porter le host sur canvas SDL (le squelette déjà prouvé, juste à intégrer au host).
4. Piège connu à respecter : `SDL_AppIterate` spinne au repos → throttle via `SDL_WaitEventTimeout` quand `!dirty`.

**Vérif** : comptage lifecycle + 0-frame repos + JSON bench s1/s5/s8 par plateforme. **Agent** : macOS child (1,2) · Windows child (2) · moi (3, web). Claim à revérifier : `SurfaceId` génération — invariant "un resize ne réutilise jamais une surface morte".

---

## K2 — Texte, TextField+IME, sémantique, widgets, LazyList, gallery

**État** : `kx_para` retenu fait · arbre `ui.zig` + hit-test + `Anim` fait · 7/7 tests.

**Étapes ordonnées** :

1. **LazyList + ScrollView** (le widget qui prouve la perf) : virtualization (créer seulement les items visibles + overscan), `clip_rect` sur le viewport, `pointer wheel` + drag-scroll, inertie via `Anim` (fling = spring `out_cubic` ou friction). Mesure : 10 000 items, frame budget 16ms prouvé sur llvmpipe + 60fps-visé sur Metal.
   - *Réf.* : Compose `LazyColumn` (sous-composition par item visible), Flutter `ListView.builder` (détection viewport + slivers), Qt `ListView` delegates — le modèle gagnant = **layout paresseux par indice, pas d'arbre complet**. On a déjà le bon primitive : children = fenêtre calculée.
2. **Widgets de base** sur `ui.Node` : `Button` (états normal/hover/pressed/disabled — press feedback via down/up), `Toggle`, `Slider`, `Card`, `Text(label retenu)`, `Icon`, `Spacer`/`Divider`, `ListTile`. Chaque widget = un custom-draw + handler, jamais de nouveau type natif.
3. **TextField + IME** : state machine (focus, caret position, sélection), `SDL_StartTextInputWithProperties` + `SDL_SetTextInputArea(bounds)` + **contournement clavier Android** (scroll-to-visible nous-mêmes — bug SDL #13166), composition `TEXT_EDITING` (pré-edit string soulignée — requis CJK/IME). Touches : delete/arrows/home/end/clipboard (SDL_GetClipboardText).
   - *Réf.* : Flutter `EditableText` = séparé du focus ; on fait pareil : `TextField` node détient `TextEditingState`. **SDL livre le pont** (TEXT_INPUT/TEXT_EDITING/StartTextInput/SetTextInputArea) — il ne reste que le modèle d'édition + scroll-into-view, identique à l'archi Flutter/Qt. Pas de lib IME réutilisable (rien n'existe chez personne, chaque framework écrit la sienne).
4. **Arbre sémantique — implémentation maison** (décision 2026-10-04 : AccessKit écarté, c'est du Rust → même pénalité que Wasmi ; approche Flutter/Qt réduite à notre échelle). `Node.semantics {label, role, hint, actions}` parallèle à paint + extraction d'un arbre sémantique plat (commun à tous les ponts). Ponts par plateforme, **par ordre de ROI** : **web = couche DOM cachée ARIA** (comme Flutter web `semantics mode` — le plus facile, haute valeur) → Android `AccessibilityNodeProvider`+TalkBack via JNI shim → iOS `UIAccessibilityContainer` → Windows UIA (`IRawElementProviderSimple`) → Linux AT-SPI (le plus pénible, dernier). **SDL n'aide pas → tout est à nous.** Version minimum viable : labels+roles+focus order, TalkBack Android prouvé.
5. **Gallery** : page démo = LazyList de toutes les widgets + TextField + toggles, tournant sous le host (le point 1 de K2 alimente sa liste). La gallery est la démo milestone.

**Vérif** : zig tests pour layout/scroll/hit ; capture d'écran gallery par backend ; TalkBack liste les items sur Android ; IME pré-edit visible en chinois/japonais sur iOS sim + web.

**Agents** : moi (1,2,3+state machine,5 — cœur framework) · Android child (IME+TalkBack vérifs réelles) · macOS child (UIAccessibility bridge + IME iOS) · Windows child (UIA bridge si faisable sinon documenté).

---

## K3 — Animations, thèmes M3E, GNOME, Glass

**Étapes** :
1. Brancher `ui.Anim` au tick host (auto-dirty tant qu'une anim vit) ; **ajouter ressorts physiques** (`spring(stiffness, damping)` — M3E utilise springs, pas tweens) ; `Anim` actuel reste pour les cas simples.
2. Thème : `ui.Theme` struct (couleurs, radii, typo scale) + dynamic color (seed → palette à la M3E : algorithme tonal HCT ou simplified OKLab).
3. Glass : `kx_paint` backdrop-blur via `saveLayer` + `imageFilter` (s5 l'a mesuré : faisable sur Graphite, cher — utiliser avec parcimonie, documenté).
4. GNOME : rien d'exotique — respecter dark/light hint (`SDL_GetSystemTheme` existe) + decor via SSD/CSD selon plateforme.

**Vérif** : gallery avec thème dark/light, anim 60fps-visé, spring vs tween comparé.

---

## P0 (reste) — Premier plugin officiel + policy réseau

**État** : WAMR choisi + ABI 0.1 + SDK + host vérifié (puis supprimé). **Reste** :
1. Premier plugin officiel = **scanner fichiers locaux** (musique) — `op=scan` → liste pistes. Justifie `vh_host.read` côté FS sandboxé (capability-gated).
2. **Policy réseau** : manifest `permissions: ["network:<domaine>"]` → host applique allowlist dans `vh_host.request` (le deny-test existe déjà dans le selftest, à porter côté config réelle).
3. Bump WAMR 2.4.4 (CVE fast-interp) + reconstruire le host-runtime (il a été supprimé avec vehicoule — reconstruire `runtime.zig` standalone sous `klaxon/` ou un crate `pluginhost/` séparé).

**Agent** : moi ou un enfant Linux — pas de dépendance plateforme.

---

## K4 — Parité desktop (Linux, Windows), iOS complet, gallery wasm publique

- Windows : host K1 + gallery + vérifs natives (a11y UIA).
- iOS "complet" : device réel requis (jamais exécuté — honnêteté). Documenté comme **bloqué-matériel** jusqu'à ce que tu aies un device.
- Gallery wasm publique : W0 harnais + gallery compilée wasm → page statique (pas de publication sans accord).

---

## Découpage agents (max 4 concurrents + moi)

| Agent | Plateforme | Missions |
|---|---|---|
| Moi (parent) | Linux + web | K2 cœur (LazyList, widgets, TextField state, sémantique tree, gallery) + K1-web + K3 base (springs+thème) + P0 reste |
| Enfant A | Windows | K1-win host → K2 UIA a11y → K4-win parity |
| Enfant B | macOS | K1-mac host → K2 iOS-sim IME + UIAcessibility → iOS complet si device un jour |
| Enfant C | Android | K2 IME-avoid + TalkBack réel + LazyList perf sur émulateur + 16KiB confirmé |
| Enfant D | (libre) | P0 plugin officiel + policy réseau **ou** K3 springs/thèmes — selon ce que je fais moi-même |

**Règle de merge** : chaque enfant livre code + test + JSON + doc sur sa plateforme ; j'intègre/valide le code commun (ui.zig, kx_skia) localement — pas de conflit car les enfants touchent leur plateforme, moi le noyau.

## Ordre global suggéré

1. **Maintenant** : dispatcher K1 macOS/Windows (enfants libres) + moi sur K2 LazyList.
2. K2 complet → gallery = démo milestone.
3. P0 reste (peut tourner sur l'enfant libre pendant K2).
4. K3 après K2 (anims utiles à la gallery).
5. K4 en continu une fois K2 stable.
