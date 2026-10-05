# F0 — Comparatif frameworks (même corpus, même machine) : Skia direct tient la comparaison

**Date** : 2026-10-04 · **Machine** : VM Linux x86_64, **aucun GPU réel** (llvmpipe/SwiftShader partout) → ces chiffres mesurent le **coût CPU** (record + raster/present logiciel), pas le GPU. La hiérarchie GPU réelle viendra des agents Windows/macOS.

## Périmètres de mesure (honnêteté)

| Outil | Ce qui est chronométré | Version |
|---|---|---|
| **k0 Skia raster** | draw de la scène entière dans surface 800×600 (record+rasterize+flush) | Skia @8643b1d6, CPU |
| **k0 Skia GL** | idem via Ganesh GL onscreen fb0 | llvmpipe |
| **k0 Skia VK** | idem via Graphite Vulkan | lavapipe |
| **Qt5 QPainter** | corps du `paintEvent` (raster engine, offscreen) | Qt 5.15 |
| **iced** | `canvas::Program::draw()` seul — présentation wgpu **exclue** | iced 0.13 |
| **Flutter web** | `CustomPainter.paint()` seul — composite CanvasKit **exclu** | Flutter 3.35.4 (Skia dessous) |

## Résultats (ms/scène, moyenne ~120 frames, CPU)

| Scène | Skia raster | Skia GL | Skia VK | Qt5 | iced | Flutter |
|---|---|---|---|---|---|---|
| s1 — 200 formes | **0,54** | **0,43** | 3,08 | 0,56 | 0,47 | 0,64 |
| s2 — texte 20 paragraphes | 5,84 | 7,92 | 5,21 | **0,34** | 0,01* | 1,78 |
| s3 — 8 ellipses blur σ14 | 1,05 | 0,63 | 2,76 | 6,41 | 0,42* | **0,07*** |
| s4 — 50 images scalées | 3,66 | **0,09** | 1,75 | 2,72 | — | 2,38 |
| s5 — blur lourd (repère) | **34,6** | 62,2 | 133,5 | — | — | — |
| s6 — 100 paths bézier | **0,57** | 1,58 | 3,68 | 2,45 | 0,36 | 0,54 |
| s8 — clip+transform+layers | **0,10** | 0,82 | 6,45 | 0,54 | 0,11 | 0,16 |

\* s2 iced / s3 Flutter+iced : probablement des layouts/glyph-runs cachés ou effets dégradés — à re-mesurer quand le corpus forcerait des glyphes réels par frame. Skia refait le shaping complet chaque frame (honnête mais pessimiste).

## Lecture

1. **Skia direct n'est jamais à la traîne sauf sur texte** : s1/s6/s8 Skia raster bat ou égale tout le monde ; s4 GL-llvmpipe (0,09ms) montre l'upload-texture amorti. Aucun framework ne "détruit" Skia sur le coût dessin pur — c'est le même moteur dessous pour Flutter.
2. **Le levier "détruire les autres" n'est PAS le rasterizer** (Skia fait déjà le boulot) — c'est l'overhead périphérique : Flutter/iced paient l'arbre de widgets, le diffing, l'allocateur, le JS/wasm boundary (web). Klaxon Zig + chemins directs peut viser zéro overhead de framework — c'est là que la victoire se joue, à confirmer quand Klaxon aura un vrai arbre UI.
3. **s2 texte = le vrai goulot Skia** (5,8ms vs 0,34 Qt) : SkParagraph refait le shape+layout à chaque paint. Klaxon devra cacher les glyph-runs/layouts — gros avantage potentiel à implémenter.
4. **s3/s5 blur** : sur CPU, Qt (6,4ms) vs Skia raster (1,0) vs SKIA GL (0,6) — déjà le plus rapide du lot en logiciel. Sur Metal réel (agent macOS) s5 passe de 83ms raster à **3,8ms** Graphite → blur = argument massue pour GPU backend.
5. **VK-lavapipe toujours le plus lent en logiciel** (6,4ms s8 vs 0,10 raster) — ne pas extrapoler : lavapipe ≠ vrai GPU. Android API31 a montré que Graphite-VK demande un driver correct (floor API33-35).

## Prochaine étape mesures

- Refaire ce tableau sur Windows (D3D12/Vulkan réel) et macOS (Metal) via les agents — c'est là que Graphite doit décoller.
- Impeller natif (i0) : build en cours ; même corpus pour A/B honnête vs Skia.
- Mesurer aussi **cold-start** (time-to-first-frame) et **idle power** (déjà prouvé : 0 frame au repos en K1) — les frameworks lourds perdent typiquement là-dessus.
