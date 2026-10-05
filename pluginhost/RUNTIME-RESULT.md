# RUNTIME-RESULT — PluginRuntime Zig/WAMR (P0 restant)

`pluginhost/` = le sandbox de production qui remplace le runtime supprimé avec
`vehicoule/`. WAMR 2.4.4 (bump depuis f5f57c0 : 2 CVE touchant fast-interp,
cf MILESTONE-PLAN) en fast-interp, libwamr.a = 597 Kio.

## Architecture

- `src/wamr.zig` — externs C fidèles à `wasm_export.h` (RuntimeInitArgs extern
  complet, NativeSymbol 4×ptr).
- `src/policy.zig` — manifeste `"permissions":[...]` : grants `network:<dom>`
  (exact / `*` / `*.<dom>`), `fs:read:<prefix>`, `fs:write:<prefix>`,
  `scan:<prefix>` (frontière de segment exigée). Grants inconnus ignorés.
- `src/natives.zig` — `vh_host.{request,read,release}` enregistrés WAMR :
  - `request("scan:<dir>")` → JSONL `{path,size}` des fichiers média
    (.mp3/.flac/.ogg/.opus/.m4a/.wav/.aac/.wma)
  - `request("fs:read:<path>")` → contenu (cap 8 Mio)
  - `request("http(s):<url>")` → policy network puis `nosys` (transport différé)
  - `read(handle,ptr,cap)` chunks, `release(handle)`
  - Registre global mutexé — correct sous le contrat **single-flight** de
    l'ABI v0.1 (1 appel vh_call en vol). Multi-flight → attachment/instance.
- `src/runtime.zig` — budgets ADR-0007 : validation LEB des sections AVANT
  `wasm_runtime_load` (mem min/**max déclaré** ≤1024 pages=64Mio — absent =
  rejet comme mémoire non bornée ; table min ≤65536 ; exports `vh_alloc` +
  `vh_call` requis), fuel par appel (`instruction_count_limit`), deadline
  wall-clock par watchdog thread (`wasm_runtime_terminate`), sortie
  `validate_app_addr` + cap 8 Mio, stack 64 Kio heap 0.

## Selftest : 11/11 PASS

```
toy / hostile_rec / edge_mem64  : validate ok
hostile_table (min 1M)          : TableLimit
edge_mem64 (min+max 1024 p.)    : accepté (seuil pile)
toy-search                      : hit attendu + hostcall sans crash
fuel-loop                       : trap "instruction limit" à 10 ms
deadline-terminate              : terminé à 303 ms (deadline 300) ★
bounded-output                  : claim 100 Mio refusé
fuel-recursion                  : trappée (fuel 50k)
scanner-deny                    : request refusé sans grant scan:
scanner-allow                   : tracks .mp3+.flac sur fixture
RESULT:PASS
```

★ **Correction P0 majeure** : le claim « terminate <200ms » du P0-RESULT
n'avait jamais été exercé (cas `NONE` désactivé dans main_wamr.c, et sans
`WASM_ENABLE_THREAD_MGR` l'API ne fait que poser le message — la boucle
continue jusqu'au fuel : mesuré 2603ms). Avec `THREAD_MGR=1` +
`thread_manager.c`, `CHECK_SUSPEND_FLAGS` coupe réellement : 303ms.
Flag ajouté à pluginhost/build.sh et P0-RESULT corrigé.

## Premier plugin officiel : `examples/scanner` (9,7 Kio)

`{"op":"scan","dir":...}` → `vh_host.request("scan:"+dir)` (capacité
`scan:` du manifeste) → liste `{title,path,size}`. Justifie la capacité FS
du manifeste — la policy deny est prouvée par scanner-deny.

## Pièges

- `zig build-lib -femit-bin` en 0.17 émet une **archive ar**, pas du wasm
  brut → corpus rebuild via `build-exe -fno-entry -rdynamic --max-memory`.
- `register_natives` trie le tableau **in-place** → NativeSymbol en `var`,
  sinon segv rodata (gdb stack: qsort_r).
- Wasm sections : mémoire **sans max = rejet** (grow non borné — résiduel P0
  fermé par la gate, pas par la confiance au flag).
- 0.17 : `std.once`/`std.fs.cwd()`/`std.Thread.Mutex`/`argsAlloc` absents →
  `std.c.pthread_mutex_*`, `std.Io.Dir`+`io`, `std.process.Init`,
  `std.os.linux.nanosleep/clock_gettime`.
- `watchdog` écrire `instructions_to_execute` NE TUE PAS la boucle en cours
  (compteur copié en local à l'entrée de fonction) — THREAD_MGR requis.

## http transport réel (post-P0)

- `http(s):` était nosys → **implémenté** : `std.http.Client.fetch` (GET only)
  + `BoundedSink` custom = writer std.Io à cap fixe `MAX_HTTP=16 Mio` — un
  serveur ne peut pas gonfler la mémoire hôte (`error.OverCap` → `Err.toobig=-6`).
- **Policy airtight** : `redirect_behavior = .unhandled` — suivre un redirect
  vers un domaine non-autorisé contournerait le allowlist `network:` ; on
  refuse les hops (status 3xx non-2xx → Err.io). Non-2xx → Err.io.
- `hostOf(url)` = host extrait avant match (`scheme://` strip, `/`, `?`, `#`,
  `:port`). `pol.allows(.network, host)` — exact | `*` | `*.dom`.
- Bloquant sous g_mutex — acceptable en single-flight v0.1 (documenté).
- Tests : `zig test src/natives.zig` — GET réelle example.com retourne du
  contenu + BoundedSink dépassement → WriteFailed+over. `./test.sh` =
  runtime(6)+policy(1)+natives(2) zig tests + selftest 11/11.

## Multi-flight : policy par instance (post-P0)

- `wasm_runtime_set_custom_data(inst, InstData*)` porte la policy de CHAQUE
  module — plus de `setPolicy` global ni swap autour de call. Deux plugins
  aux grants différents coexistent correctement.
- `ensureInstData` crée l'attachement lazy (alloc hôte) ; `Module.call`
  pose `d.policy = opts.policy` + reset à null après ; `Module.unload`
  `detach()` AVANT deinstantiate.
- Mutex global réduit à `g_pending` (handles de réponses). httpGet/readFile
  bloquants restent sous ce mutex — sérialise les plugins en IO concurrente,
  honnêteté v0.1 (un mutex par instance + map global lock-free = chantier
  suivant si besoin réel).

## Isolation des handles (correctif multi-flight)

- `Pending.owner` = instance propriétaire : `read`/`release` d'un handle
  créé par un AUTRE module → `badh` (un plugin ne peut plus sonder les
  réponses d'un voisin en itérant les ids).
- `detach(inst)` purge aussi les pendings orphelins de l'instance à
  l'unload (fuites bornées à `reset` sinon).
