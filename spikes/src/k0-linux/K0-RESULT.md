# K0 Linux natif — Verdict

**Date** : 2026-10-04 · **Machine** : VM cloud x86_64 sans GPU (rendu logiciel : Mesa llvmpipe) · **Skia** : `8643b1d6` build `out/linux` (12 .a, GN args `scripts/build_skia_linux.sh`, clang-14 + `skia_use_partition_alloc=false`).

⚠️ **Tous les chiffres sont en rendu logiciel** — llvmpipe simule le GPU sur CPU. Ces résultats mesurent la correction + le coût CPU, pas la perf GPU réelle (aux agents natifs).

## Résultats (corpus 9 scènes 480×800, JSON dans `results/`)

| Backend | Driver | Verdict | first-frame | Scènes notables |
|---|---|---|---|---|
| raster | `raster-cpu` | ✅ PASS 9/9 | 1 813 ms | référence MAE=0 |
| Ganesh GL | `ganesh-gl(llvmpipe;Mesa)` (EGL surfaceless) | ✅ PASS 9/9 | 4 417 ms | s8 mae 7.25 · s5 60ms vs 34 raster |
| Graphite Vulkan | `graphite-vulkan(llvmpipe)` | ✅ PASS 9/9 | 8 780 ms | s2 mae 3.06 · s8 mae 4.07, nw_g>nw_r |

Sévérité des MAE : cohérentes avec le wasm (AA/rasterisation différente GPU vs raster ; s8/pixels = le plus divergent partout). `nw_g>0` partout : aucune image blanche. **Aucun FAIL fonctionnel sur les 3 backends.**

## Pièges résolus (réutilisables pour les autres plateformes)

1. **`VulkanPreferredFeatures`** : la séquence correcte est `init(apiVersion)` → `addToInstanceExtensions(names)` → `vkCreateInstance` → `addFeaturesToQuery(&feats2)` → `vkGetPhysicalDeviceFeatures2` → `addFeaturesToEnable(&feats2)` → `vkCreateDevice`. Le `VkPhysicalDeviceFeatures2` doit **vivre dans la struct ctx** (membre), pas en stack-local — `vk_bc.fDeviceFeatures2` le garde par pointeur.
2. **VMA obligatoire** : `VulkanBackendContext.fMemoryAllocator` → `skgpu::VulkanMemoryAllocators::Make(bc, skgpu::ThreadSafe::kYes)` (dans `src/gpu/vk/vulkanmemoryallocator/VulkanMemoryAllocatorPriv.h`, besoin de `src/gpu/GpuTypesPriv.h` pour `ThreadSafe`).
3. **Submit synchrone natif** : `Context::insertRecording` + `submit(SyncToCpu::kYes)` (`skgpu::graphite::SyncToCpu`) — pas de `fTick` à gérer contrairement au wasm.
4. **Readback graphite** : flush → `asyncRescaleAndReadPixels` → `submit(SyncToCpu::kYes)` rend le poll synchrone et fiable.
5. **EGL headless** : `eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA)` + pbuffer 1×1 + `GrGLMakeAssembledInterface` avec `eglGetProcAddress` — aucun X11 requis.
6. **GN flags manquants côté deps** : `skia_use_partition_alloc=false` (clang-14 trop vieux), `skia_use_expat/fontconfig=false` (fontmgr custom), `skia_use_libwebp_decode/encode=false` + `skia_use_no_webp_encode=true`, `skia_use_libjpeg_turbo_decode/encode=false` + `skia_use_dng_sdk=false`, `skia_use_egl=true`, `skia_use_x11=false`. `vma` + `vulkan-headers` à fetcher comme deps externes.
7. **`KxFontMgr`** : le même que W0 — `SkFontMgr_New_Custom_Empty` n'indexe pas les faces chargées par `makeFromData`, les paragraphes rendent blanc sans lui.
8. **`KxInternal.h` natif** : `kx_target` sans membres wgpu, `kx_flush_target(ctx,target)` — le `kx_scenes.cpp` partagé ne touche que `surface/dirty/onscreen`, compatible tel quel.

## Lecture des perfs (honnête)

- Sur llvmpipe, Ganesh GL est plus rapide que Graphite Vulkan sur 6/9 scènes (record+submit CPU). Inversement attendu sur GPU réel — à trancher par les agents.
- s5 (flours saveLayer) reste le plus coûteux partout (34–141 ms) : scène à surveiller pour la table de sélection backend.
- `first_frame` graphite-vk 8,8 s : compile de pipelines SPIR-V sous llvmpipe — ne pas extrapoler.

## Fichiers

`scripts/build_skia_linux.sh` · `scripts/build_app.sh` · `shim/kx_skia.h` (ABI étendue native) · `shim/kx_skia_linux.cpp` · `shim/kx_internal.h` (variante native) · `shim/kx_scenes.cpp` (copie W0) · `app/main.cpp` · `results/k0-{raster,gl,vk}.json` + `k0-linux-*.png`
