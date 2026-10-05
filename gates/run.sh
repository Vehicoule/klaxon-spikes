#!/usr/bin/env bash
# gates/run.sh — exécute les scènes de mesure K3 et évalue les gates
# (ADR-0008) : chaque résultat est une ligne JSON {artifact_sha256, target,
# abi, os, backend, driver, scene, status: PASS|FAIL|BLOCKED|SKIPPED,
# measurements, reason}. Exit != 0 si au moins un gate FAIL.
#
# Prérequis : gallery + vehicoule déjà buildés (gallery/build.sh,
# vehicoule/build.sh), X display (DISPLAY), SDL_AUDIODRIVER=dummy
# recommandé en headless.
set -uo pipefail
ROOT=/home/ubuntu/work/Klaxon
OUT="$ROOT/gates/results-$(date +%Y%m%d-%H%M%S).jsonl"
mkdir -p "$ROOT/gates"
: > "$OUT"

sha() { sha256sum "$1" | cut -d' ' -f1; }
run() { # binaire, args… → dernière ligne JSON de stderr/stdout
    timeout 60 "$@" 2>&1 | grep '^{' | tail -1
}

GAL_SHA=$(sha "$ROOT/gallery/out/gallery" | cut -c1-16)
VEH_SHA=$(sha "$ROOT/vehicoule/out/vehicoule" | cut -c1-16)

# --- scène 1 : gallery scroll réel (wheel injecté) + cold + idle ---------
scroll_json=$(run "$ROOT/gallery/out/gallery" --frames 400 --wheel 100)
idle_json=$(run "$ROOT/gallery/out/gallery" --secs 5)
cold3_json=$(run "$ROOT/gallery/out/gallery" --secs 2)   # 3e échantillon cold
# --- scène 2 : vehicoule decode+UI (formats compressés isolés) ------------
veh_json=$(SDL_AUDIODRIVER=dummy run "$ROOT/vehicoule/out/vehicoule" \
    --dir "$ROOT/vehicoule/music-test-compressed" --frames 400 --secs 20 --autoplay)

GAL_SHA="$GAL_SHA" VEH_SHA="$VEH_SHA" SCROLL="$scroll_json" IDLE="$idle_json" \
COLD3="$cold3_json" VEH="$veh_json" OUT="$OUT" python3 - <<'PY'
import json, os, sys

out_path = os.environ["OUT"]
scroll = json.loads(os.environ["SCROLL"]) if os.environ["SCROLL"] else None
idle = json.loads(os.environ["IDLE"]) if os.environ["IDLE"] else None
cold3 = json.loads(os.environ["COLD3"]) if os.environ.get("COLD3") else None
veh = json.loads(os.environ["VEH"]) if os.environ["VEH"] else None
gal_sha, veh_sha = os.environ["GAL_SHA"], os.environ["VEH_SHA"]

results = []
def record(scene, blob, tool, sha, extra=""):
    if blob is None:
        results.append({"scene": scene, "tool": tool, "status": "BLOCKED",
                        "reason": f"pas de sortie JSON{extra}", "artifact_sha256": sha})
        return {}
    blob["_sha"] = sha
    return blob

g_scroll = record("gallery-scroll", scroll, "k2-gallery", gal_sha)
g_idle = record("gallery-idle", idle, "k2-gallery", gal_sha)
g_veh = record("vehicoule", veh, "vehicoule-v0", veh_sha)

th = json.load(open(os.path.join(os.path.dirname(out_path), "thresholds.json")))

# cold start = médiane de 3 échantillons (variance llvmpipe au seuil,
# un tir unique est instable — la médiane est la mesure honnête)
cold_samples = [b.get("first_frame_ms") for b in (scroll, idle, cold3) if b]
cold_samples.sort()
cold_median = cold_samples[len(cold_samples) // 2] if cold_samples else None
for g in th["gates"]:
    src = g_scroll if g["tool"] == "k2-gallery" else g_veh
    if g["scene"] == "gallery-idle":
        src = g_idle
    if not src:
        continue
    m = g["metric"]
    v = cold_median if g["scene"] == "gallery-cold" else src.get(m)
    ok = {"<": lambda: v < g["value"], "<=": lambda: v <= g["value"],
          ">": lambda: v > g["value"], ">=": lambda: v >= g["value"],
          "==": lambda: v == g["value"]}[g["op"]]() if v is not None else False
    results.append({
        "artifact_sha256": src["_sha"],
        "target": "linux-x86_64", "abi": "gnu", "os": "linux",
        "backend": src.get("backend", "?"), "driver": src.get("driver", "?"),
        "scene": g["scene"],
        "status": "PASS" if ok else "FAIL",
        "measurements": {m: v, "avg_frame_ms": src.get("avg_frame_ms") or src.get("avg_ms"),
                          "first_frame_ms": src.get("first_frame_ms"),
                          **({"cold_samples_ms": cold_samples} if g["scene"] == "gallery-cold" else {})},
        "reason": g["reason"],
    })

fails = 0
with open(out_path, "a") as f:
    for r in results:
        if r["status"] == "FAIL":
            fails += 1
        f.write(json.dumps(r) + "\n")
        print(f'{r["status"]:>7}  {r["scene"]:<32} {json.dumps(r.get("measurements", {}))}  [{r.get("driver","?")[:40]}]')
print(f"\n{len(results)} résultats → {out_path}")
sys.exit(1 if fails else 0)
PY
