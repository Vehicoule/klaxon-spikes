# spikes/src — sources de reproduction des benchmarks

Sources et scripts possédés des spikes dont les verdicts sont consignés
dans `VERDICT-SPIKES.md` (racine) et les `*-RESULT.md` de chaque dossier.
Les artefacts régénérables (build/, out/, deps vendored, .wasm, fonts,
binaires, .dart_tool, target/, zig-cache) sont exclus volontairement —
ce dossier est la partie *reproductible* des chiffres, pas leur exécution.

| Spike | Contenu | Reproduire |
|---|---|---|
| `f0-compare/` | benches Qt (C++/Makefile), iced (Rust), Flutter (Dart) + `run_bench.py` | voir `F0-RESULT.md` |
| `i0-impeller/` | `app/main.cpp` (harness corpus) | clone `bdero/impeller-cmake` au pin engine, `deps.sh` + preset ninja (détail dans `I0-RESULT.md`) — impeller-cmake est vendored, non inclus |
| `k0-linux/` | app + shim kx_skia Linux + `scripts/build_*.sh` | scripts + Skia pin (voir `K0-RESULT.md`) |
| `k1-sdl/` | app + binding SDL (zig) | SDL3 3.2.16 + build dans `K1-RESULT-linux.md` |
| `p0-runtime/` | hosts zware/bytebox/wamr + plugins hostiles + `make_hostiles.py` | `hosts/p0/build.zig`, `p0-wamr/build_wamr.sh` |
| `w0-graphite-wasm/` | app zig + shim kx_skia + scripts fetch/build + patches emdawnwebgpu + `test/run_w0.mjs` + résultats JSON | scripts sous `scripts/`, deps via `fetch_deps_wasm.sh` (fonts = fetch, non incluses) |

Règle : tout chiffre cité dans un verdict doit être reproduisible par ce
qui est ici + les pins documentés. Si un script manque, c'est un trou à
combler, pas un choix.
