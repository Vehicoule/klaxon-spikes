# i0 — Spike Impeller natif (Linux, GLES/llvmpipe) : FONCTIONNE, mais perd face à Skia sur le même matériel

**Date** : 2026-10-04 · **Machine** : VM Linux x86_64, **llvmpipe (logiciel)** — timings CPU only · **Source** : bdero/impeller-cmake (Flutter engine @ pins des sous-modules), libs statiques `libimpeller_*` + shaders embarqués (`entity_shaders_lib` etc.).

## Ce qui a marché

- **Build reproductible** : `deps.sh` (~500Mio) + `cmake --preset ninja-debug-clang` + ninja → `libimpeller_{aiks,entity,typographer,scene,renderer,core,geometry,tessellator,base,shader_archive,runtime_stage}.a` + libs shaders GLES.
- **Patch requis** : `typographer/glyph_atlas.h` — `unordered_map<ScaledFont, FontGlyphAtlas>` utilisait un type incomplet (toléré par libc++ d'Apple, refusé par libstdc++-11) → classe `FontGlyphAtlas` déplacée avant `GlyphAtlas`.
- **Harnais** (`app/main.cpp`) : fenêtre SDL3 + contexte GLES3 (profil ES sous Mesa) → `ProcTableGLES` via `SDL_GL_GetProcAddress` → `ContextGLES::Create` + `ReactorWorker` (trivial, un thread) → `Renderer` + `AiksContext` → `SurfaceGLES::WrapFBO` par frame + `aiks->Render(canvas.EndRecordingAsPicture(), rt)`.
- **Rendu réel vérifié** : screenshot `out/i0-desktop.png` — scène s1 dessinée correctement dans la fenêtre.
- ⚠️ Un `Could not link pipeline program` (validation) sur certains pipelines — frames comptées et pixels corrects quand même ; à investiguer si Impeller devient candidat.

## Mesures (800×600, record+present, vsync off sous llvmpipe — moyenne 120 frames)

| Scène | Impeller GLES | Skia GL (Ganesh, même machine) | Skia raster | Skia VK (Graphite) |
|---|---|---|---|---|
| s1 — 200 formes | 6,47 ms | **0,43** | 0,54 | 3,08 |
| s3 — 8 ellipses blur σ14 | 1,59 ms | **0,63** | 1,05 | 2,76 |
| s4 — 50 images scalées | 2,71 ms | **0,09** | 3,66 | 1,75 |
| s6 — 100 paths bézier | 10,39 ms | 1,58 | **0,57** | 3,68 |
| s8 — clip+transform+layers | 2,89 ms | 0,82 | **0,10** | 6,45 |

## Lecture (honnête)

1. **Sur logiciel, Impeller perd partout contre Skia** — de ×2 (s3) à ×30 (s4). Sa pipeline GLES via llvmpipe paie la tessellation + architecture entity par draw call.
2. **Ce n'est PAS un verdict GPU** : Impeller est conçu pour Metal/Vulkan (GLES = son chemin le plus faible) ; llvmpipe est du CPU déguisé. Le vrai A/B = Impeller-Metal vs Skia Graphite-Metal (agent macOS le fait) — sur API31-style faiblesses driver, cf. Android.
3. **Coût d'adoption mesuré** : ~500Mio de deps, 1133 cibles, patch libstdc++ nécessaire, **zéro chemin wasm** (structural — pas de navigateur), pas de raster-CPU de secours (alors que Skia couvre déjà tout). Même à perf égale, Impeller ajoute un deuxième monde.
4. **Conclusion provisoire** : ADR-0002 (Skia seul : Graphite→Ganesh→raster) tient sur Linux-logiciel. À réviser **uniquement** si l'agent macOS montre Impeller-Metal nettement meilleur que Graphite-Metal sur le même corpus. Pas de path iOS-wasm — l'app Vehicoule web resterait Skia-only de toute façon.

## Artefacts

`impeller-cmake/` (deps + libs), `app/main.cpp` (harness corpus), `out/i0` (42Mio), `results/i0-s{1,3,4,6,8}.json`, `out/i0-desktop.png`, `out/i0-s1-log.txt` (log pipeline-link). Scène s2 (texte) non portée — typographer construit mais TextFrame API pas testée (impacterait seulement la comparaison texte).
