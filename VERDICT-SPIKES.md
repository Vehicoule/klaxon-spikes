# VERDICT SPIKES — Klaxon/Vehicoule (agrégation au 2026-10-04)

Verdict global des spikes pré-implémentation. **Tout ce qui est marqué PASS a été exécuté** ; les timings logiciels/émulateur ne sont jamais extrapolés au hardware (consignés `driver` dans chaque JSON).

## Résumé exécutif

| Spike | Question | Verdict |
|---|---|---|
| **W0** | Skia wasm : Graphite/WebGPU + Ganesh/WebGL2 + raster + link Zig ? | **PASS 9/9 sur les 3 backends** — Skia compilé avec les trois chemins dans un seul binaire de 6,9 Mio linké à du Zig. emdawnwebgpu reconstruit depuis Dawn épinglé ; patch de migration API webgpu nécessaire (inclus). |
| **K0** | Skia natif reproductible + corpus par plateforme ? | **PASS partout sauf graphite-VK API31** (fail honnête). macOS/Metal sur GPU réel : blur s5 = **3,8ms vs 83,7ms raster (×22)**. iOS sim Metal : ×19. Windows : **4/4 backends** (dawn-D3D12, dawn-Vulkan, ganesh-GLon12, raster) — tout logiciel (WARP/lavapipe), qualification pipeline pas perf HW. |
| **P0** | Runtime WASM plugins : bytebox / zware / WAMR ? | **WAMR gagne** — seul avec metering hermétique (fuel per-dispatch sur TOUS les opcodes) + `wasm_runtime_terminate` cross-thread <200ms. bytebox : trou Loop/Branch dans le metering. zware : aucun metering. Host-side budgets = à implémenter dans PluginRuntime (gap universel). |
| **K1** | Hôte SDL3 + lifecycle + 0-frame-au-repos ? | **Linux + iOS + Android PASS** (0 frames au repos des 3 côtés ; Android : rotation ×2 `surface_recreates`, HOME pause/resume, LOW_MEMORY ; piège : `SDL_AppIterate` spinne libre au repos → throttle requis en prod). |
| **F0** | Perf vs frameworks (Qt, iced, Flutter) ? | Skia direct **jamais à la traîne** sauf texte (s2 : 5,8ms vs 0,34 Qt — Skia re-shape à chaque frame ; Klaxon devra cacher les glyph-runs). Le levier de victoire = overhead framework, pas le rasterizer. |
| **i0** | Impeller natif (hors ADR-0002, sur demande utilisateur) ? | **ADR-0002 CONFIRMÉE sur les 3 fronts — Impeller éliminé** : ×2-×30 logiciel (Linux), ×1.4-×4.3 **vrai GPU Metal** macOS (7/9 scènes), ×2.4-×13 **iOS-sim Metal** (9/9 scènes, plancher/frame ~2.5ms vs ~0.65 Skia : surcoût MSAA×4+transients). Seules victoires marginales : s8 points ×0.79 macOS, first-frame ~65ms plus rapide. Réserve : engine épinglé impeller-cmake, pas tête Flutter. |
| **App** | Squelette klaxon+vehicoule end-to-end ? | **PASS** (puis `vehicoule/` **supprimé** sur demande utilisateur — focus framework) : Zig 0.17 → SDL3 GL → kx_draw v1 (paint/canvas/para/image) → UI lecteur dessinée + interactive (clic ▶/⏸ vérifié), PluginRuntime WAMR 7/7 budgets ADR-0007. À reconstruire au chantier app (spec : P0-RESULT + ADR-0007). |
| **K2** | Arbre UI retenu + layout + hit-test ? | **PASS** : `klaxon/src/ui.zig` — Node tree (axis row/column/leaf, Size px|weight, gap/pad/cross), layout 2-pass flex, hitTest descendant z-order, dispatch pointer. Démontré : lecteur = 8 nodes statiques, clic sur ▶ toggle play/pause (icône échange), prev/next changent la piste + rebuild des paras. |

## Table de sélection backend (par donnée mesurée)

| Plateforme | Primaire | Fallback | Evidence |
|---|---|---|---|
| macOS | **graphite-metal** | raster | s5 3,8ms vs 83,7 raster ; GL soft = Apple Software Renderer sur VM (non pertinent HW) |
| iOS | **graphite-metal** | raster | sim PASS 9/9 ; device non exécuté (honnête) |
| Android ≥API33-35 | graphite-vulkan | ganesh-gles | Venus API31 → validate FAIL ; floor réel à confirmer par appareil |
| Android <API33 | ganesh-gles | raster | fallback mesuré PASS sur API31 |
| Linux | graphite-vulkan | ganesh-gl → raster | 3/3 PASS sur lavapipe/llvmpipe ; ordre GPU-réel à confirmer sur hardware |
| Windows | **graphite-dawn-d3d12** | dawn-vulkan → ganesh-gl → raster | 4/4 PASS mais WARP/lavapipe/GLon12 = logiciel ; pipeline complet record→insertRecording→submit→readback vérifié ; ordre sur GPU réel à confirmer |
| Web | graphite-webgpu | ganesh-webgl2 → raster | W0 9/9 les 2 GPU chemins ; raster toujours dispo |

## Ce que les données tranchent

1. **Graphite-metal est le choix gagnant sur Apple** — seul backend GPU réel disponible (GL soft = inutile sur Apple Silicon VM ; Metal compile les pipelines au first-frame ~1s → pré-chauffer au splash).
2. **Android Graphite-Vulkan a un floor** : Venus (API31) échoue `VulkanInterface::validate` → **ganesh-gles obligatoire sous API33-35**, Graphite au-dessus. 16KiB page-size = `-Wl,-z,max-page-size=16384`.
3. **WAMR est le runtime plugins** : metering par instruction qui couvre loops/branches/recursion (bytebox troué, zware absent). Host PluginRuntime doit ajouter : validation des limites déclarées au load, fuel par appel, deadline 30s via thread+terminate, sorties bornées ≤8Mio, pile ≤64Kio.
4. **Impeller éliminé, données à l'appui (3 OS, 3 mesures indépendantes)** : perd ×2-×30 logiciel (Linux), ×1.4-×4.3 Metal réel macOS (7/9 scènes), ×2.4-×13 Metal iOS-sim (9/9). ADR-0002 (Skia-only) confirmée — le test utilisateur a fermé la question. Note honnêteté : iOS-sim engine = pin impeller-cmake (pas tête Flutter).
5. **Perf-vs-frameworks** : Skia ≈ ou > Qt/iced/Flutter sur CPU partout sauf s2-texte → Klaxon doit cacher les glyph-runs → **implémenté dans `kx_para`** (objet paragraphe retenu : layout unique, repaint par frame).
6. **0-frame-au-repos prouvé** en SDL3/Zig (483 idle iters) et sur iOS sim (181 iters / 0 frames).
7. **iOS traps consignés** : `skia_enable_graphite=false` par défaut au pin ; SkiaStyleSet immortalité pour skparagraph (double-unref sinon) ; ReleaseFast requis (ReleaseSafe casse sur `NullFile.fd`).
8. **PluginRuntime Zig/WAMR bouclé** : fuel + deadline-watchdog + validate_app_addr + gate des limites déclarées (mem/table) — 7/7 cas (hostiles + sdk_search). Résiduel `memory.grow` fermé par `--max-memory` du SDK.
9. **Windows build traps** (doc enfant) : Dawn se build **CMake pas GN** (+deps `third_party/externals/`) ; `icudtl.dat` requis à côté de l'exe ; tout en `/MT` (MT_StaticRelease) ; `dawn_enable_vulkan` off par défaut ; link Zig x86_64-windows-msvc vérifié (`kx_zig.exe` 9/9).

## Reste à clore

- K1 SDL3 : macOS/Windows (non dispatchés — prochaine mission enfants libres).
- GPU-réel à re-mesurer : Windows (VM WARP-only), Android physique, Linux avec GPU, iOS device. Tous les timings émulateur/software sont de la qualification pipeline, pas de la perf hardware — consigné `driver` dans chaque JSON.
- Tous les agents enfants ont rapporté : Windows K0 4/4 · macOS K0+i0 · iOS K0+K1+i0 · Android K0+K1.
- K2 suite : texte déjà posé (`kx_para`) + arbre UI fait (`ui.zig`) ; prochains = widgets réels (scroll, list, input), animations, accessibility.

## Fichiers

`spikes/w0-graphite-wasm/W0-RESULT.md` · `spikes/k0-linux/K0-RESULT.md` · `spikes/p0-runtime/P0-RESULT.md` · `spikes/k1-sdl/K1-RESULT-linux.md` · `spikes/f0-compare/F0-RESULT.md` · `spikes/i0-impeller/I0-RESULT.md` · `results/` (JSON + docs enfants : k0-ios.md, k0-macos.md, k0-android.md, k1-ios.md, kx36-api36/).

**Arborescence implémentation** (cette session) : `klaxon/src/{klaxon,kx,sdl,host,ui}.zig` (bindings C ABI + host SDL3 avec dirty-flag + arbre UI/anim), `kx_skia/{include/kx_skia.h,src/kx_draw.cpp}` (API dessin v1 ~40 fns), `sdk/` (Plugin SDK Zig). ~~`vehicoule/`~~ supprimé — focus framework (app lecteur + PluginRuntime à reconstruire plus tard).
