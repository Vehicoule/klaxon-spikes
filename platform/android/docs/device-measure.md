# Mesurer les gates V1 sur un device réel

Prérequis : `adb` dans le PATH (Android platform-tools), débogage USB
activé sur le téléphone, et l'APK Vehicoule (`vehicoule-v1.apk`).

```sh
# 1. Brancher le téléphone, vérifier
adb devices            # doit lister le device "device" (pas "unauthorized")

# 2. Lancer les gates (installe l'APK, pousse les fixtures, joue, mesure)
./gates/device.sh --apk /chemin/vehicoule-v1.apk
```

Le script :
- installe l'APK (`adb install -r`), pousse `vehicoule/music-test/` dans
  le sandbox app (`files/music`),
- lance la scène `vehicoule` via `am start -e kx_args "--dir files/music
  --frames 400 --secs 30 --autoplay"` (même canal que le transport debug),
- récupère `files/vehicoule.json` (stats réelles : frames, p99, pacing,
  RSS, fed, media_cmds),
- évalue les mêmes seuils `gates/thresholds.json` et écrit un
  `gates/results-device-<ts>.jsonl` au format ADR-0008 — `driver` porte
  `device:<modèle> sdk<N>` ; un émulateur est détecté et marqué
  explicitement (jamais extrapolé à du hardware).

Options : `--serial <id>` (multi-devices), `--gallery-apk <apk>` (scènes
gallery), `--strict-hw` (émulateur → SKIPPED au lieu de PASS marqué).

Exit 1 si un gate FAIL. Les seuils sont les provisoires llvmpipe : la
première exécution sur device réel sert à recalibrer `thresholds.json`
(fork `thresholds-device.json` à ce moment-là si les baselines divergent).
