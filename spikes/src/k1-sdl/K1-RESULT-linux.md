# K1 — Spike SDL3 host (Linux) : PASS

**Date** : 2026-10-04 · **Machine** : VM Linux x86_64 · **Driver** : `ganesh-gl-current(llvmpipe (LLVM 15.0.7, 256 bits);Mesa)` — rendu logiciel, timings = coût CPU record+present.

## Ce qui est prouvé

| Capacité | Résultat | Preuve |
|---|---|---|
| Build SDL3 3.2.16 pinned (cmake, shared) | ✅ X11 + Wayland + Vulkan compilés | `deps/SDL3-build/libSDL3.so` |
| Hôte **Zig 0.17** complet | ✅ `zig build-exe` + translate-c bindings (`app/kx_sdl.zig` 9,7K lignes générées — pattern prod : `@cImport` n'existe plus en 0.17) | `app/main.zig` |
| Skia onscreen via contexte GL courant | ✅ `kx_ctx_create_ganesh_gl_current(SDL_GL_GetProcAddress)` + `kx_target_onscreen_gl` (WrapBackendRenderTarget fb0, GrBackendRenderTargets::MakeGL) | screenshot `out/k1-desktop.png` |
| Rendu réel à l'écran | ✅ scène s1 vectoriel affichée dans vraie fenêtre X | `out/k1-desktop.png` |
| Lifecycle : resize/expose/minimize | ✅ events SDL_EVENT_WINDOW_* comptés ; target recréée au resize | JSON resizes/exposes |
| **0 frame au repos** | ✅ mode `rest` : 2 frames en 2s (init + expose), **483 itérations idle sans présentation** | `k1-linux-s1.json` |
| First-frame | ~25-75ms selon scène (inclut MakeGL+fontes 1ère fois) | JSON |

## Mesures (bench mode, 120 frames, vsync SDL — llvmpipe ne throttle pas)

| Scène | avg frame | first |
|---|---|---|
| s1 vectoriel (200 formes) | 1,85 ms | 29,3 ms |
| s6 paths (100 béziers) | 4,43 ms | 74,7 ms |
| s8 composite | 1,73 ms | 31,6 ms |

## Pièges trouvés (documentés pour prod)

1. **`eglQueryString(EGL_NO_DISPLAY, EXT)` → NULL → Skia segfault** : sous GLX, `eglGetCurrentDisplay()` rend 0 ; Skia `GrGLExtensions::init` appelle `eat_space_sep_strings(NULL)` sans check. **Fix hôte : ne pas exposer `egl*` dans le get_proc quand le contexte n'est pas EGL** (masquer `egl*`). À coder dans le getproc prod.
2. **Zig 0.17** : `@cImport` supprimé → `zig translate-c` produit `app/kx_sdl.zig` (à regénérer au bump SDL/ABI). `std.fs` vidé → `std.Io.Dir.*` + `init.io`. `std.process.Init` obligatoire pour argv/io. `-lc++` link le mauvais stdlib pour objets clang/libstdc++ → linker `/usr/lib/gcc/.../libstdc++.a + libgcc_eh.a + libgcc.a` explicitement.
3. `SDL_GL_SetSwapInterval(1)` ne throttle pas sous llvmpipe/GLX — les mesures ne sont pas plafonnées à 60Hz (bien pour le bench, à re-valider sur GPU réel).
4. `std.fmt.allocPrint` sur gpa → leak-report du SafeAllocator en fin ; utiliser bufPrint (fait).

## Statut K1 par plateforme

- **Linux** : ✅ ce doc — SDL3 + Zig + Skia onscreen + lifecycle de base.
- Windows/macOS/iOS/Android : à faire par les agents quand K0 fini (spec = ce harness + rotation/Activity-recreation/stale-surface selon plateforme). Le mobile a aussi `SDL_EVENT_WILL_ENTER_BACKGROUND/FOREGROUND`.
- Graphite-Vulkan onscreen (swapchain Vulkan + RenderTarget par image) : **non fait** — chemin plus lourd, à prioriser après les résultats enfants K0 (decide si Graphite prime sur Ganesh onscreen).

Fichiers : `deps/SDL3*` (build pinned), `app/main.zig`, `app/kx_sdl.zig` (bindings générés), `app/kx_sdl.h`, `out/app/k1-sdl`, `out/k1-linux-s*.json`, `out/k1-desktop.png`. Le shim a gagné `kx_ctx_create_ganesh_gl_current` + `kx_target_onscreen_gl` (dans `k0-linux/shim/`).
