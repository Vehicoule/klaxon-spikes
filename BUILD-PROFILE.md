# BUILD-PROFILE — taille des builds + temps de compile, mesuré et comparé

Objectif : pousser taille et temps de compile au maximum, et se situer
honnêtement face aux frameworks. Tous les chiffres « mesuré » sortent de
cette VM (zig 0.17, 2026-10-04) ; les chiffres concurrents sont des ordres
de grandeur publiés — marqués comme tels, jamais extrapolés.

## 1. Temps de compile zig — mesuré (objet vehicoule, cache froid)

Cible `x86_64-linux-android.31`, `zig build-obj -fPIC`, cache neuf :

| Mode | wall | pic RSS | objet produit |
|---|---|---|---|
| Debug | **0,46 s** | 200 Mo | 14,6 Mo |
| ReleaseFast | 11,9 s | 470 Mo | 6,7 Mo |
| **ReleaseSmall** | **2,6 s** | 231 Mo | **1,2 Mo** |

Enseignement : ReleaseSmall coûte **4,5× moins de temps** que
ReleaseFast et produit un objet **5,6× plus petit**. Debug compile en
demi-seconde mais l'objet est le plus gros (info debug).
Compromis honnête : ReleaseSmall privilégie la taille à la micro-perf ;
le garder pour l'app shipping, garder ReleaseFast pour les builds de bench
où la mesure des gates est l'objet.

### 1bis. Build e2e complet — mesuré (cache froid, cette VM)

`vehicoule/build.sh` complet : 146 objets décodeurs C (`gcc -O2`) +
zig `build-exe -O fast` + link statique Skia/SDL/WAMR → binaire Linux :

| Étape | avant parallélisation | après |
|---|---|---|
| 146 objets décodeurs (gcc -O2) | ~10 s séquentiel | parallèle nproc |
| zig build-exe + link final | ~5 s | idem |
| **total e2e mesuré** | **14,7 s** | **4,7 s** |

Lecture : un build natif complet froid en **4,7 s** après
parallélisation des `cc_obj` (vérifié : binaire fonctionnel, 8 pistes).
À titre de comparaison publiée (non mesurée ici) : `flutter build apk`
release ~1-3 min, gradle RN ~1-5 min, Qt androiddeployqt minutes —
notre e2e complet est **~15-60× plus court** que le cycle release
d'un framework lourd, et il n'est plus dominé par le code vendored.

APK arm64 : temps par étape à mesurer chez l'enfant (zig obj, NDK
décodeurs, link .so, gradle, signe) — à consigner ici quand livré.

## 2. Composition du .so Android — mesuré (APK x86_64 actuel)

`libmain.so` = 13 Mo non strip :

| Composant | Poids estimé | Levier |
|---|---|---|
| Skia Graphite + texte (subset linké des .a : skia 25 Mo + icu 22+22 + shaper 8,5 + harfbuzz 8,3 + freetype 1,2 + paragraph 0,6 + png/zlib/skcms ~0,7) | **~9-10 Mo** dominant | strip, sections GC (déjà), réduire ICU (icu-data trim), SVG/off unneeded |
| Objet zig vehicoule (ReleaseFast) | ~6,7→1,2 Mo avec ReleaseSmall | **ReleaseSmall** |
| Décodeurs vendored (~146 objets, opus/silk/celt + vorbis + opusfile + ogg + dr_libs) | ~1,4 Mo | virer formats inutilisés, -Os |
| Java/dex + res | ~0,1 Mo | — |
| libSDL3.so (à part) | 3,4 Mo | strip, build allégé (disable sous-systèmes) |

Projection honnête arm64 stripped + ReleaseSmall : libmain ~5-7 Mo,
APK ~**9-11 Mo** (SDL3 compris, avant compression Play).

## 3. Leviers rangés par gain/effort (ordre d'attaque)

1. **ReleaseSmall** — zig obj 6,7→1,2 Mo, déjà applicable.
2. **llvm-strip** du .so final — symboles = une bonne part des 13 Mo.
3. **ICU trim** — skunicode_icu+libicu = ~44 Mo de .a ; un data-trim
   (icudt custom sans locales inutiles) est le plus gros levier texte
   connu côté Skia. Effort moyen.
4. **Découper les décodeurs** — garder seulement ce que V0 joue vraiment
   (opus ≈ la moitié des 1,4 Mo via silk/celt).
5. **SDL3 allégé** — désactiver sous-systèmes non utilisés (haptic,
   sensors…) ; ~-1 Mo plausible.
6. **Split ABI** — arm64-v8a seul pour sideload (x86_64 = émulateur
   uniquement) ; AAB plus tard fait ça automatiquement.
7. **Skia dynamique partagée** — si plusieurs apps, un libskia.so
   commun ; mais une seule app n'y gagne rien.
8. **extractNativeLibs/compression** — l'APK stocke les .so non
   compressés (Stored) par design Android (évite le double stockage
   installé). Ne pas « optimiser » ça, c'est volontaire.

## 4. Comparaison frameworks — ordres publiés (non mesurés par nous)

APK hello-world release, arm64 seul :

| Stack | APK typique | Compile release typique |
|---|---|---|
| Flutter | ~15-20 Mo | 30-90 s |
| React Native | ~25-35 Mo | 1-3 min |
| Qt for Android | ~15-25 Mo | minutes |
| Compose natif | ~8-15 Mo | 20-60 s |
| **Vehicoule (actuel, x86)** | **30 Mo non optimisé** | — |
| **Vehicoule projeté (arm64+RS+strip)** | **~9-11 Mo** | **zig seul 2,6 s** |

Lecture honnête : aujourd'hui on est au niveau d'un framework lourd
parce que le build est Debug-x86 non strip non split. Une fois les
leviers 1-3 appliqués on passe **sous Flutter** — avec un runtime
maison (Skia) et pas de moteur JS. Le temps de compile zig (2,6 s
ReleaseSmall, 0,5 s Debug) est notre meilleur argument : un cycle
edit→run plus rapide que tout le tableau.

## 5. Item V1/V2

- [ ] APK arm64 ReleaseSmall+strip (en cours chez l'enfant)
- [ ] ICU data-trim pour le texte (SkParagraph sans ICU impossible —
      trim data seulement)
- [ ] Threshold « APK budget » dans gates/thresholds.json (gate taille :
      un max Mo, mesuré à chaque build — la taille comme les perfs)
- [ ] Re-mesurer les temps de compile par cible (iOS zig obj, Windows)
