# W0 — Spike Graphite/WebGPU + Ganesh/WebGL + raster en wasm32-emscripten

Date : 2026-10-04. Machine : VM Linux x86_64 **sans GPU** (tout rendu est logiciel —
voir "Limites de mesure"). Statut : **terminé, verdict positif**.

## Verdict court

`zig build-obj -target wasm32-emscripten` + link `em++` avec Skia (Graphite/Dawn
via emdawnwebgpu + Ganesh/WebGL2 + raster dans le MÊME binaire) **fonctionne**.
Les 9 scènes du corpus passent en PASS sur les deux backends GPU simulés, avec
MAE mesurée contre raster et garde-fou anti-blanc (`nw_r`/`nw_g`). Le canvas
onscreen présente correctement.

- `w0.wasm` = **7 233 855 octets** (6,9 Mio) — `zig -OReleaseSmall` + shim + Skia
  complet (paragraph+icu+harfbuzz+freetype+png+zlib).
- `w0.js` = 239 502 octets.

## Limites de mesure (honnêteté des chiffres)

- Pas de GPU : WebGPU tourne sur **SwiftShader** (adaptateur logiciel) via
  `--enable-unsafe-webgpu --use-webgpu-adapter=swiftshader`; WebGL idem via
  ANGLE/SwiftShader. `driver` dans les JSON = `graphite-webgpu(emdawnwebgpu;
  adapter=browser)` / Ganesh-WebGL.
- Les `bench_ms` mesurent le coût **CPU** record+snap+submit Skia (pas le
  raster GPU) ; les `raster_bench_ms` sont le CPU raster pur. Ne PAS extrapoler
  aux machines avec GPU réel — c'est le rôle des agents K0 natifs.
- `first_frame_ms` ≈ 2,1 s inclut le temps du premier run incluant upload
  texture + warm-up SwiftShader ; valeur à re-mesurer sur vrai matériel.

## Résultats (mediane de 30 itérations, MAE vs raster, pixels 480×800)

### Graphite/WebGPU (emdawnwebgpu reconstruit depuis Dawn épinglé) — PASS

| scène | mae | bench_ms | raster_ms | non-blanc r/g |
|-------|-----|----------|-----------|----------------|
| s0 composite | 0.077 | ~2.0 | 17.8 | 75k |
| s1 rrects×160 | 0.213 | 0.29 | 0.9 | 318k |
| s2 cubiques×80 | 3.11 | 0.16 | 6.6 | ~91k |
| s3 gradients×96 | 0.0006 | 0.66 | 12.0 | 384k |
| s4 images×96 | 0.515 | 0.24 | 24.6 | 320k |
| s5 blurs σ4×12 | 0.376 | 1.45 | ~185 | ~157k |
| s6 clips×24 | 0.095 | 0.30 | 0.65 | 242k |
| s7 paragraphs×30 | 0.022 | 0.9 | 1.1 | ~32k |
| s8 pixels | 4.08 | 0.80 | 0.15 | ~23k |

### Ganesh/WebGL2 — PASS (mêmes seuils)

mae ∈ [0.022 … 7.25] (s8 le plus élevé : dithering/atlas SwiftShader).
bench ∈ [0.2 … 3.7 ms] vs raster 0.2 … 191 ms.

### WebGPU désactivé (`--no-webgpu`)

`navigator.gpu.requestAdapter → null` → status FAIL immédiat, erreur propre,
pas de crash. Fallback applicatif (WebGL) = décision produit à brancher dans
Klaxon (le harnais laisse le choix au caller via `?backend=`).

## Pièges rencontrés et corrigés (à garder pour K0/natif)

1. **Build Skia wasm compile Dawn natif** → patch `0001` : groupe GN `dawn`
   réduit aux defines sur `is_wasm`.
2. **API webgpu emscripten obsolète** → emdawnwebgpu **reconstruit depuis les
   sources Dawn épinglées** (générateur `dawn.json` → `webgpu.h`/`webgpu.cpp` +
   `webgpu_struct_info` emscripten) plutôt qu'une release précompilée ;
   patch `0002` : blocs `__EMSCRIPTEN__` de `src/gpu/graphite/dawn/*` migrés
   vers l'API actuelle (`MapAsyncStatus`, `ShaderSourceWGSL`,
   `PassTimestampWrites`, `TexelCopy*`, callbacks `AllowSpontaneous`).
3. **`DawnBackendContext.fTick` doit rester `nullptr`** — un tick non-nul
   réactive `CreateRenderPipelineAsync` qui abort littéralement en wasm.
   Conséquence : contexte non-yielding → `fAllowCpuSync=false` → tout readback
   se fait en rAF (`asyncRescaleAndReadPixels` + `submit()` +
   `checkAsyncWorkCompletion()`).
4. **SkImage raster non dessinable sur Graphite** ("couldn't convert") →
   conversion texture via `SkImages::TextureFromImage(recorder, img, {})`.
5. **`SkFontMgr_New_Custom_Empty().makeFromData` n'indexe PAS les faces** par
   famille → `KxFontMgr` maison (SkFontMgr_Custom-like) avec fallback
   `onMatchFamilyStyleCharacter` par couverture `unicharToGlyph`.
6. **`--pre-js` requis** (pas `--extern-pre-js`) + `var Module = typeof
   Module !== 'undefined' ? Module : {};` en tête d'app.js.
7. Renommages d'API à ce pin : `GrDirectContexts::MakeGL`,
   `GrBackendRenderTargets::MakeGL(w,h,samples,stencil,{fFBOID})`,
   `SkImages::RasterFromData`, `SkShaders::LinearGradient(pts, SkGradient{...})`,
   `drawPoints(mode, SkSpan, paint)`, `Recorder` uniquement via
   `ctx->makeRecorder()`.
8. Readback ImageFilter/Blurs très coûteux en CPU raster (s5 : ~185 ms) —
   surveiller sur configs faibles ; c'est aussi un argument pour le bench
   "pires configs" de la matrice K0.

## ADR-0002 — recommandations issues du spike

- Graphite/WebGPU **viable en wasm** avec emdawnwebgpu reconstruit depuis le
  pin Dawn — mais coût : patch `0002` à maintenir à chaque bump de Skia
  (migration API webgpu sur 9 fichiers).
- Le graphe de fallback `Graphite → Ganesh → raster` est validé dans le MÊME
  binaire (3 ctx créés côte à côte, sélection runtime par `?backend=`).
- MAE < 5 partout, jamais d'image blanche grâce à `nw_*` — le protocole de
  vérification K0 réutilise ce garde-fou.
- Prochaine mesure décisive : natif GPU réel (agents K0) — ces chiffres
  logiciels ne prouvent que la correction, pas la perf.

## Reproduction

```
tools: zig 0.17.0, emsdk 4.0.7 (node 24.19), depot_tools, Chrome-for-Testing 137
bash scripts/fetch_deps_wasm.sh   # skia@8643b1d6 + dawn@2c217c7f + pkg emdawnwebgpu regen
bash scripts/build_skia_wasm.sh   # gn + ninja → deps/skia/out/wasm/*.a (patches 0001+0002)
bash scripts/build_app_wasm.sh    # shim/*.o + zig main.zig + em++ → app/w0.{js,wasm}
python3 -m http.server 8093 -d .  # racine spike
node test/run_w0.mjs webgpu       # PASS → test/results/w0-webgpu.{json,png}
node test/run_w0.mjs webgl        # PASS
node test/run_w0.mjs webgpu --no-webgpu  # FAIL propre (adapter null)
```

## Addendum (2026-10-05) — kx_draw v1 porté en wasm

Le même `kx_draw.cpp` (API v1 : paint/canvas/para/image) compile et link sous emscripten dans `w0.wasm` (+~0,35Mio). Accessoires requis ajoutés au shim wasm : `kx_ctx_graphite_recorder` (GRAPHITE_WEBGPU) et `kx_ctx_gr_context` (GANESH_WEBGL) + decls fonts dans `kx_internal.h`.

Preuve d'exécution : `kx_draw_smoke` (export Zig) dessine rrect dégradé + cercle + paragraphe via l'API v1 sur le ctx raster, readback sync → `nw=89553` non-fond = **PASS** sur `?backend=webgl` ET `?backend=webgpu` (corpus 9/9 PASS inchangé dans les deux runs).

Conséquence : l'ABI C `kx_skia.h` est portable telle quelle natif↔wasm — le même code applicatif Zig (`klaxon.kx`) cible les deux.
