# sdk — Vehicoule Plugin SDK (Zig, ABI v0.1 / ADR-0007)

SDK first-class pour écrire des plugins WASM en Zig : le contrat ABI est
câblé par le module `src/vh.zig`, le plugin n'écrit que son handler.

## Usage

```zig
const std = @import("std");
const vh = @import("vh");

comptime { _ = vh; }             // force l'émission des exports
pub const vhHandler = handle;    // point d'entrée métier (root decl)

fn handle(req: []const u8, a: std.mem.Allocator) ![]u8 {
    // req = payload de l'hôte (≤ 8 Mio) ; a = scratch arena resettée post-call.
    // Retourner la réponse allouée depuis a — le SDK pack (len<<32)|ptr.
}
```

## Build obligatoire

```bash
zig build-exe -target wasm32-freestanding -O ReleaseSmall \
    -fno-entry -rdynamic --max-memory=67108864 \
    --dep vh -Mroot=main.zig -Mvh=<chemin>/sdk/src/vh.zig \
    -femit-bin=plugin.wasm
```

| Flag | Rôle |
|---|---|
| `-fno-entry` | pas de `start` (ADR-0007 : wasm MVP+bulk-memory, pas de WASI/start) |
| `-rdynamic` | émet les exports `vh_alloc`/`vh_free`/`vh_call` |
| `--max-memory=67108864` | **déclare `mem.max=1024 pages`** — la gate de limites du host (`readLimits`) l'exige ; sans elle `memory.grow` est non borné (résiduel P0 fermé par cette déclaration) |

## Vérifié

`search.wasm` (8 002 octets) produit par `examples/search/build.sh` :
- section mémoire : `min=17 max=1024` (exactement le cap host 64 Mio)
- exports : `vh_call`, `vh_free`, `vh_alloc`, `memory`
- imports : `vh_host.request`/`read`/`release`

Rejoué à travers `PluginRuntime.callPlugin` (`vehicoule/zig build selftest`) :
`{"op":"search","args":{"q":"sub"}}` → 135 B contenant les hits attendus,
`call_ms=0,40`, 0 requête hôte. Résumé selftest : **7/7 PASS** (6 hostiles + sdk_search).

## Convenances

- `vh.hostRequest(payload) !i32` — envoie ≤ 8 Mio, retourne un handle
- `vh.hostReadAll(h, a, cap) ![]u8` — lit la réponse
- `vh.hostRelease(h)` — libère le handle
- `vh.MAX_PAYLOAD` — cap miroir host
- Handler absent → réponse `{"error":"NoHandler"}` (jamais de crash)
- Erreur de handler → `{"error":"<errorName>"}` (pas de trap wasm)

## Limites connues (v0.1)

- Un seul appel en vol (wasm single-thread MVP — l'arena est globale).
- `hostReadAll` borne par `cap` passé par le plugin (le host borne à 8 Mio).
- Pas de `vh_free` effectif : l'arena recycle tout au reset post-call — par design.
