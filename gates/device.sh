#!/usr/bin/env bash
# gates/device.sh — exécute les scènes de mesure sur un device Android
# branché en adb (ou émulateur) et évalue les mêmes gates ADR-0008 que
# run.sh. Usage : gates/device.sh [--apk path/to.apk] [--serial SERIAL]
#
# Honnêteté : le modèle/SDK/driver réel du device est consigné dans
# chaque résultat (driver = stats driver + "device:<model> sdk<N>").
# Émulateur détecté (ro.kernel.qemu/goldfish/ranchu) → status SKIPPED
# sur les gates de perf calibrées hardware si --strict-hw, sinon PASS
# mais marqué émulateur — JAMAIS extrapolé à du device physique.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/gates/results-device-$(date +%Y%m%d-%H%M%S).jsonl"
APK=""
GAL_APK=""
SERIAL=""
STRICT_HW=0
FIXTURES="none"
PKG=org.libsdl.app
while [ $# -gt 0 ]; do case "$1" in
  --apk) APK="$2"; shift 2;;
  --gallery-apk) GAL_APK="$2"; shift 2;;
  --fixtures) FIXTURES="$2"; shift 2;;
  --serial) SERIAL="$2"; shift 2;;
  --strict-hw) STRICT_HW=1; shift;;
  *) echo "usage: device.sh [--apk p] [--gallery-apk p] [--fixtures dir] [--serial s] [--strict-hw]"; exit 2;;
esac; done
ADB="adb ${SERIAL:+-s $SERIAL}"

# --- prérequis -------------------------------------------------------------
# adb : PATH, puis ANDROID_HOME/ANDROID_SDK_ROOT/platform-tools.
if ! command -v adb >/dev/null; then
  for c in "${ANDROID_HOME:-}/platform-tools/adb" \
           "${ANDROID_SDK_ROOT:-}/platform-tools/adb"; do
    [ -x "$c" ] && PATH="$(dirname "$c"):$PATH" && break
  done
fi
command -v adb >/dev/null || { echo "adb absent (platform-tools : PATH ou ANDROID_HOME)"; exit 2; }
command -v python3 >/dev/null || { echo "python3 absent"; exit 2; }
# APK : --apk requis sauf s'il en existe un dans ./ ou deliverables/ voisins.
if [ -z "$APK" ]; then
  for d in "." "$ROOT" "$ROOT/../deliverables" "$HOME/Downloads" "$HOME/Téléchargements"; do
    APK=$(ls -t "$d"/vehicoule-*.apk 2>/dev/null | head -1)
    [ -n "$APK" ] && break
  done
fi
[ -f "${APK:-}" ] || { echo "APK introuvable — passe --apk /chemin/vehicoule-*.apk"; exit 2; }
echo "apk: $APK"
$ADB get-state >/dev/null 2>&1 || { echo "aucun device adb connecté"; exit 2; }

MODEL=$($ADB shell getprop ro.product.model | tr -d '\r' | tr ' ' '_')
SDK=$($ADB shell getprop ro.build.version.sdk | tr -d '\r')
HW=$($ADB shell getprop ro.hardware | tr -d '\r')
EMU=$($ADB shell getprop ro.kernel.qemu | tr -d '\r')
ABI=$($ADB shell getprop ro.product.cpu.abi | tr -d '\r')
IS_EMU=0
case "$EMU$HW" in *1*|*goldfish*|*ranchu*|*emu*) IS_EMU=1;; esac
echo "device: $MODEL (sdk $SDK, abi $ABI, hw $HW) émulateur=$IS_EMU"

# --- install + fixtures ----------------------------------------------------
$ADB install -r "$APK" >/dev/null || { echo "adb install KO"; exit 2; }
# fixtures : depuis v1.1 la musique démo est embarquée dans l'APK
# (assets → files/music au 1er boot). Le push adb ne sert que pour un
# APK pré-v1.1 ou un contenu perso via --fixtures. Optionnel, jamais fatal.
if [ "$FIXTURES" != "none" ] && [ -d "$FIXTURES" ]; then
  $ADB push "$FIXTURES" /data/local/tmp/kx-fixtures >/dev/null && \
  $ADB shell 'run-as '"$PKG"' sh -c "mkdir -p files/music && cp -r /data/local/tmp/kx-fixtures files/music 2>/dev/null || cp /data/local/tmp/kx-fixtures/* files/music/ 2>/dev/null || true"' 2>/dev/null || \
    echo "warn: fixtures non copiées (run-as requiert un build debuggable — non fatal)"
fi

run_scene() { # nom, kx_args, fichier stats → JSON ligne (ou vide)
    local name="$1" args="$2" stats="$3"
    $ADB shell "run-as $PKG rm -f $stats" 2>/dev/null
    $ADB shell am force-stop "$PKG"
    # -W : attend l'activité affichée → WaitTime ≈ tap-icon→1re frame,
    # complément OS au ttff_ms in-app (process spawn compris).
    local start_out wait_ms total_ms
    start_out=$($ADB shell am start -W -n "$PKG/.SDLActivity" --es kx_args "$args" 2>&1)
    wait_ms=$(echo "$start_out" | sed -n 's/.*WaitTime: \([0-9]*\).*/\1/p' | tail -1)
    total_ms=$(echo "$start_out" | sed -n 's/.*TotalTime: \([0-9]*\).*/\1/p' | tail -1)
    for i in $(seq 1 60); do
        sleep 2
        local j
        j=$($ADB shell "run-as $PKG cat $stats 2>/dev/null" | tr -d '\r' | tail -1)
        case "$j" in \{*)
            # injecte la latence de lancement OS dans le résultat
            j="${j#\{}"
            echo "{\"launch_wait_ms\":${wait_ms:-null},\"launch_total_ms\":${total_ms:-null},$j"
            return;;
        esac
    done
    echo ""
}

apk_sha=$(sha256sum "$APK" | cut -c1-16)
veh_json=$(run_scene vehicoule \
    "--dir /data/data/$PKG/files/music --frames 400 --secs 30 --autoplay" \
    files/vehicoule.json)
gal_json=""
if [ -n "$GAL_APK" ] && [ -f "$GAL_APK" ]; then
    $ADB install -r "$GAL_APK" >/dev/null
    gal_json=$(run_scene gallery "--frames 400 --wheel 100 --secs 45" files/k4-gallery.json)
fi

OUT="$OUT" VEH="$veh_json" GAL="$gal_json" SHA="$apk_sha" \
APK="$APK" \
MODEL="$MODEL" SDK="$SDK" ABI="$ABI" EMU="$IS_EMU" STRICT_HW="$STRICT_HW" \
python3 - <<'PY'
import json, os, sys

out_path = os.environ["OUT"]
emu = os.environ["EMU"] == "1"
strict = os.environ["STRICT_HW"] == "1"
dev = f'{os.environ["MODEL"]} sdk{os.environ["SDK"]}'
veh = json.loads(os.environ["VEH"]) if os.environ["VEH"] else None
gal = json.loads(os.environ["GAL"]) if os.environ["GAL"] else None
sha = os.environ["SHA"]
th = json.load(open(os.path.join(os.path.dirname(out_path), "thresholds.json")))

apk_mb = os.path.getsize(os.environ["APK"]) / 1e6
results = []
def driver(blob):
    base = (blob or {}).get("driver", "?")
    return f'{base};device:{dev}{" EMULATEUR" if emu else ""}'

for g in th["gates"]:
    src = veh if g["tool"] == "vehicoule-v0" else gal
    if g["scene"].startswith("gallery-") and src is None:
        results.append({"scene": g["scene"], "status": "SKIPPED",
                        "reason": "pas d'APK gallery (--gallery-apk)",
                        "artifact_sha256": sha})
        continue
    m = g["metric"]
    if m == "apk_mb":
        # la taille est une propriété du fichier, pas du runtime device
        v = apk_mb
        ok = {"<": lambda: v < g["value"], "<=": lambda: v <= g["value"],
              ">": lambda: v > g["value"], ">=": lambda: v >= g["value"],
              "==": lambda: v == g["value"]}[g["op"]]()
        results.append({
            "artifact_sha256": sha,
            "target": f'android-{os.environ["ABI"]}', "abi": os.environ["ABI"],
            "os": f'android-{os.environ["SDK"]}',
            "backend": "-", "driver": f'apk-file;device:{dev}',
            "scene": g["scene"], "status": "PASS" if ok else "FAIL",
            "measurements": {"apk_mb": round(v, 1)},
            "reason": g["reason"]})
        continue
    if src is None:
        results.append({"scene": g["scene"], "status": "BLOCKED",
                        "reason": "pas de JSON stats device", "artifact_sha256": sha})
        continue
    v = src.get(m)
    if emu and strict:
        status, ok = "SKIPPED", True
        reason = f'{g["reason"]} — émulateur : jamais extrapolé hardware'
    else:
        ok = {"<": lambda: v < g["value"], "<=": lambda: v <= g["value"],
              ">": lambda: v > g["value"], ">=": lambda: v >= g["value"],
              "==": lambda: v == g["value"]}[g["op"]]() if v is not None else False
        status = "PASS" if ok else "FAIL"
        reason = g["reason"] + (" [émulateur, non extrapolé]" if emu else "")
    results.append({
        "artifact_sha256": sha,
        "target": f'android-{os.environ["ABI"]}', "abi": os.environ["ABI"],
        "os": f'android-{os.environ["SDK"]}',
        "backend": src.get("backend", "?"), "driver": driver(src),
        "scene": g["scene"], "status": status,
        "measurements": {m: v, "avg_ms": src.get("avg_frame_ms") or src.get("avg_ms"),
                         "rss": src.get("peak_rss_mb"), "pacing": src.get("pacing_p99_ms"),
                         "ttff_ms": src.get("ttff_ms"),
                         "launch_wait_ms": src.get("launch_wait_ms")},
        "reason": reason})

fails = sum(1 for r in results if r["status"] == "FAIL")
with open(out_path, "w") as f:
    for r in results:
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f'  {r["status"]:<8}{r["scene"]:<28}{json.dumps(r.get("measurements", {}), ensure_ascii=False)[:90]}')
print(f'\n{len(results)} résultats → {out_path}')
sys.exit(1 if fails else 0)
PY
