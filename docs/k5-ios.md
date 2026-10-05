# K5-iOS — revalidation canon4 : 3 fixes + UIAccessibility end-to-end

Plateforme : simulateur iOS arm64, iPhone 17 / iOS 26.5.
Driver : `graphite-metal(Apple iOS simulator GPU)` — paravirt, non extrapolé.
Base : `klaxon-canon4.tar.gz` (contrat ABI gelé : `ident` = `void*` keyed
`(uint64_t)(uintptr_t)`, retours `int`).
Statut : **PASS** — 3 fixes revérifiés sur base canonique + activate→action
prouvée par compteur.

## Build

`gallery/build_gallery_ios.sh` canonique, inchangé. Deux retouches locales
nécessaires (diff `results/k5-ios.diff`, 670 lignes) :

1. **`klaxon/src/ui.zig` : `alloc.dupeZ` → `alloc.dupeSentinel(u8, s, 0)`** —
   `dupeZ` n'existe plus en zig 0.17 (renommée). Même sémantique (sentinelle
   requise par le shim ObjC). *Retouche de portabilité à remonter.*
2. **`kx_skia/src/kx_skia_ios.cpp` restauré** — canon4 ne livre que
   macos/linux ; le platform file iOS (GL stripé — GLES iOS deprecated) est
   requis. Bloc fonts remplacé par le schéma canonique : `dirty` lazy +
   `kx_fonts_collection` rebuild + **`kx_fonts_family_index`** +
   **`kx_fonts_add_dir`** (scan .ttf/.otf/.ttc récursif POSIX — porté tel
   quel, `#include <algorithm>/<cctype>` ajoutés).

## Les 3 fixes — revérifiés sur base canonique

| # | Fix | Preuve canon4 |
|---|---|---|
| 1 | `kx_ios_window_mapped` + warmup dirty jusqu'à map+200ms | Rendu visible dès le boot, 0 intervention (capture `k5-boot.png`) |
| 2 | `translate(ev, ptr_scale)` — coords point→pixel ×3 | Tap réel (530,500) → `Piste #30` sélectionnée (surbrillance + trait `0x48`) — pas de décalage ×3 |
| 3 | `SDL_SetTextInputArea` bounds÷scale | Instrument temporaire : `px(428,70,768,36) ÷3.0 → pt(142,23,256,12)` — identique au frame a11y |

## UIAccessibility end-to-end

- **97 éléments** énumérés (gallery canonique plus dense : container
  'Bibliothèque', icônes toolbar). Ordre DFS top→down.
- Traits mesurés : Header `0x10000`, Button `0x1`, Adjustable `0x1000`,
  textfield `0x0`+element, StaticText `0x40`, **Selected `0x48`**
  (StaticText|Selected sur `Piste #30` — flag `it.selected` → `A11Y_SELECTED`
  → `UIAccessibilityTraitSelected`, chaîne complète).
- Idents `0x10…` (void*) — pool keyed `(uint64_t)(uintptr_t)`, réutilisation
  stable (mutation en place prouvée : SELECTED posé post-tap, même ident).
- **Activate → action** : `accessibilityActivate()` (Button 'Ajouter 100
  pistes') → cb zig `a11yPress` → `pointer_down/up` synthétiques → `onAdd100`
  → **`items: 10100`** dans le JSON bench (vs 10000) — preuve chiffrée.
- Notifications : ScreenChanged au 1er arbre, LayoutChanged à chaque mutation.

## Pièges de cette itération (à consigner)

1. **Attachment URL → curl = "Unauthorized" JSON** — toujours
   `download_attachment`, jamais curl sur les liens app.devin.ai.
2. **`dupeZ` renommé `dupeSentinel` (zig 0.17)** — signature
   `(T, slice, sentinel)`.
3. **`--frames N` sort avant les timers a11y** — le bench force le dessin
   continu (~12ms/frame canonique) ; pour capturer dump+stats dans le même
   run : `--frames 400 --a11y-at 2500` (le dump doit tomber avant la fin du
   budget frames).
4. **Toolbar sous la status bar = zone morte** — le champ TextField
   (y≈23-35pt) n'est pas tappable ; le focus passe par `--inject` (qui fait
   `focused=true` + `onFieldFocus` avant de pousser TEXT_INPUT) — seam de
   test documentée, pas un bug.
5. **`items:10100`** — le dump `kx_a11y_debug_dump` active le 1er trait
   Button à chaque tir (périodique 6s) : penser que ses +100 s'accumulent si
   le bench compte les items.

## Fichiers

- `results/k5-ios.json` — JSON de vérif (ce doc en est le résumé).
- `results/k5-ios.diff` — retouches vs canon4 (ui.zig + kx_skia_ios.cpp).
- `results/k5-boot.png`, `results/k5-tap-selected.png` — captures sim.
- `results/k4canon.log` (dumps périodiques), `k4bench2.log` (items:10100),
  `k4tf2.log` (rect pt), `k4tap.log` (traits dont 0x48).
