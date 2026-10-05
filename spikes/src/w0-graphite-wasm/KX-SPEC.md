# KX-SPEC — protocole partagé des spikes rendu (W0 fait, K0 natif par plateforme)

Tout spike de backend doit produire les mêmes artefacts pour être comparable :
`results/k0-<plateforme>-<backend>.json` + `.png` + un petit doc de notes.

## Corpus (identique partout, surface 480×800, RGBA8888, fond blanc)

- s0 composite : fond blanc + titre + 8 vignettes des scènes 1-8
- s1 : 160 rrects (grille 8×20, radius variable)
- s2 : 80 chemins de 6 cubiques, stroke 1.5
- s3 : 96 rects à gradient linéaire
- s4 : 96 images 64×64 (damier procédural déterministe)
- s5 : 12 saveLayers Blur σ4
- s6 : 24 clips rrect avec chemin cubic dedans
- s7 : 30 paragraphes SkParagraph multi-scripts (latin/arabe/CJK/emoji, fontes
  embarquées Roboto+NotoNaskh+NotoSansCJK+NotoColorEmoji)
- s8 : 2×1024 drawPoints

## Mesures par scène

- `mae` : |r−g| moyen sur R+G+B vs raster CPU du même Skia, en unités/255.
- `nw_r`, `nw_g` : pixels non-blancs (<250 sur un canal) — garde-fou
  blanc-vs-blanc ; une scène non vide exige nw>0 des deux côtés.
- `bench_ms` : médiane 30 itérations du chemin complet (record+submit+readback
  côté Skia ; inclure le present/finalize du backend).
- `raster_bench_ms` : même boucle sur surface raster.

## JSON de rapport

```
{ "status":"PASS|FAIL", "driver":"<backend;adapter/driver réel>",
  "init_ms":…, "first_frame_ms":…, "fonts":N,
  "scenes":{"s0":{"mae":…,"nw_r":…,"nw_g":…,"bench_ms":…,"raster_bench_ms":…},…},
  "errors":[…] }
```

Règles : PASS = les 9 scènes dessinées sans crash, `nw>0`, mae<~10 ;
FAIL = crash, image blanche, ou API absente — rapporter l'échec honnêtement,
ne pas extrapoler. Consigner dans `driver` le vrai backend (ex.
`graphite-vulkan(lavapipe)`, `ganesh-gl(llvmpipe)`, `graphite-metal`, …).

## ABI C commune (shim `kx_skia.h` — 1 fichier .h + .cpp par plateforme)

Contextes : `kx_ctx_create_{raster,ganesh_gl,graphite_vulkan,graphite_metal,
graphite_dawn_d3d12,graphite_webgpu}`. Surfaces : `kx_target_offscreen(ctx,w,h)`
+ hooks onscreen (`kx_target_canvas` wasm / `kx_target_window` natif). Dessin :
`kx_scene_draw(ctx, fonts, target, scene, phase)`. Readback :
`kx_readback_{start,poll,copy,free}` (poll=0 non prêt / 1 prêt / <0 échec —
s'insère dans la boucle événementielle, jamais de wait bloquant synchrone
là où le backend l'interdit). Bench : `kx_bench_ms(ctx,fonts,target,scene,iters)`.
Fontes : `kx_fonts_add(f,data,len)` (tolerate TTC), `kx_fonts_count`,
`kx_fonts_global`.
