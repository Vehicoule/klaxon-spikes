# P0 — Spike runtime WASM : Verdict

**Date** : 2026-10-04 · **Machine** : VM Linux x86_64 · **Candidats testés** : bytebox `652b68f`, zware `8384227`, WAMR `main` (fast-interp). Corpus : toy plugin Zig→wasm32 (`toy.wasm`, ABI vh_alloc/vh_call + imports vh_host) + 4 modules hostiles (boucle infinie, memory.grow 256 Mio + sortie 100 Mio, récursion infinie, table min=1M, mémoire min=64Mio).

## Verdict : **WAMR fast-interp** — recommandé pour `PluginRuntime`

| Critère ADR-0007 | WAMR fast-interp | bytebox (.Stack) | zware |
|---|---|---|---|
| Fuel / comptage d'instructions | ✅ `wasm_runtime_set_instruction_count_limit` — décrémente **chaque** dispatch d'opcode ; boucle infinie tuée à 6,4ms (fuel 5M) | ⚠️ existe MAIS **trou fatal** : `Loop/Branch/Branch_If/Branch_Table/Drop` exemptés → `while(true){}` échappe au fuel (>25s, jamais trappé) | ❌ aucun metering |
| Annulation cross-thread | ⚠️→✅ `wasm_runtime_terminate(inst)` — **corrigé au P0-run : sans `WASM_ENABLE_THREAD_MGR=1` l'API ne fait que poser l'exception, la boucle continue** (le cas cancel du harnais C n'a jamais tourné : gardé derrière `NONE`). Avec THREAD_MGR : `CHECK_SUSPEND_FLAGS` tue la boucle à ~deadline (mesuré 303ms pour 300ms, pluginhost selftest) | ❌ aucune API de cancel trouvée | ❌ aucune |
| Récursion infinie | ✅ fuel=50k → "instruction limit exceeded" en 0,2ms | ❌ hang >15s (fuel ne la rattrape pas) | ❌ hang (timeout externe) |
| Limites mémoire | ⚠️ honore les `max` déclarés wasm ; **pas de cap hôte** — `vh_alloc` a grow 4096 pages = **257 Mio alloués** → hôte doit valider les limites déclarées au load | idem : 257 Mio alloués sans cap | idem (max honoré, min=64Mio alloué) |
| Table | ❌ accepte min=1M sans broncher (à valider au load par l'hôte) | idem | idem |
| Sorties bornées | ✅ `wasm_runtime_validate_app_addr` — le claim 100 Mio sur mémoire 1 page détecté (`ret_valid:false`) | manuel (memoryAll + borne) — détecté aussi | manuel — détecté |
| Conformité spec | Bytecode Alliance, spec testsuite upstream | bonne (testsuite interne) | testsuite partielle |
| Pas de JIT (iOS) | ✅ interpréteur pur | ✅ | ✅ |
| Taille hôte | **349 Kio** binaire harnais complet | ~10 Mio+ (Debug, zig) | ~10 Mio+ (Debug, zig) |
| Perf (toy, call) | **1,0 ms** | 1,4 ms (Debug) | 0,2 ms (Debug, mais sans garde) |
| Intégration Zig 0.17 | via shim C `wasm_export.h` (stable, documentée) | ❌ **build.zig incompatible zig ≥0.16** (`addCSourceFile`/`b.args` supprimés) — testé sous zig 0.15.2 | ⚠️ module zig ≥0.16 (0.15 refuse `.always_tail` sans LLVM), 0.17 à vérifier |

## Configuration WAMR éprouvée (flags requis pour les modules zig)

```
WASM_ENABLE_INTERP=1 FAST_INTERP=1 AOT=0 JIT=0
BULK_MEMORY=1 BULK_MEMORY_OPT=1   # memory.copy/fill = OPT séparé !
REF_TYPES=1 CALL_INDIRECT_OVERLONG=1  # zig émet call_indirect tableidx LEB (0x80 0x00)
INSTRUCTION_METERING=1            # sinon pas de fuel
WAKEUP_BLOCKING_OP=1              # terminate cross-thread
THREAD_MGR=1                    # OBLIGATOIRE pour que terminate interrompe réellement (CHECK_SUSPEND_FLAGS)
BH_MALLOC=wasm_runtime_malloc BH_FREE=wasm_runtime_free
```

`LABELS_AS_VALUES` doit rester activé (défaut) : en mode switch classique le check d'instruction/terminate n'est pas évalué à chaque op — les hostiles pendent à nouveau (régression mesurée).

## Budgets hôtes à implémenter (aucun runtime ne les fournit)

1. **Validation au load** : refuser mémoire min>1024 pages / max>1024 pages, table min>65536 (bytebox, zware ET WAMR acceptent table 1M — vérifié).
2. **Fuel par invocation** : 200M interactif / 2G opération longue — `set_instruction_count_limit` avant chaque `call_wasm`.
3. **Deadline 30s** : thread watchdog + `wasm_runtime_terminate` — **nécessite `WASM_ENABLE_THREAD_MGR=1`** (sinon no-op, cf. correction ligne annulation). Mesuré 303ms sur deadline 300ms.
4. **Sortie bornée** : `validate_app_addr(pptr, plen)` + copie ≤8Mio cumulé — le claim 100 Mio est systématiquement détecté.
5. **Stack** : `wasm_runtime_instantiate(stack=64Kio)` + exec_env stack — la récursion meurt du fuel AVANT l'overflow (mesuré).

## Non testé

- **Wasmi** : nécessite une toolchain Rust (pénalité ADR explicite). WAMR couvre les mêmes garanties sans Rust dans le build — verdict WAMR inchangé.
- Perf sur JSON 1Mio : la fixture fait ~500 o ; WAMR ~1ms/appel, bytebox ~1,4ms (Debug), zware ~0,2ms mais sans aucune garde. Les chiffres restent du même ordre — pas de facteur 10.
- iOS/Android : les agents plateforme peuvent re-tester la compilation WAMR (C89/99 portable, pas de JIT) dans K1.

## Recommandation ADR-0007

**Runtime hôte = WAMR fast-interp derrière `PluginRuntime` Zig** (shim C fin : `wasm_export.h`, ~10 fonctions). bytebox et zware ratent le critère n°1 (confinement) ; un runtime Zig maison resterait une option de long terme mais n'est pas nécessaire au jalon 1.

Fichiers : `plugin/*.zig`, `plugin/make_hostiles.py`, `hosts/p0/` (zig hosts bytebox+zware), `hosts/p0-wamr/` (C host), `results/*.json`, `hosts/wamr/` (clone épinglé).
