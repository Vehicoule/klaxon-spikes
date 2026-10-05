# K4-iOS — port UIAccessibility (bridge arbre sémantique → UIKit)

Plateforme : simulateur iOS arm64, iPhone 17 / iOS 26.5.
Driver : `graphite-metal(Apple iOS simulator GPU;sim)` — GPU paravirt, rien d'extrapolé au device.
Statut : **PASS** — contrat gelé implémenté et vérifié de bout en bout.

## Décisions

- **Fichier séparé `kx_a11y_ios.mm`** (pas de `#if TARGET_OS_IOS` dans `kx_a11y.mm`) : les types diffèrent presque partout (NSView vs UIView, NSAccessibility* vs UIAccessibility*), le partage aurait été un #if par méthode — plus sale qu'un fichier dédié.
- **Pas de hit-test custom** : contrairement à macOS (accessibilityFrameInParentSpace + hit-test maison), iOS fait le hit nativement — on déclare juste `view.accessibilityElements` trié DFS top→down.
- **Container = la UIView SDL** (`SDL_MetalView`, opaque `void*`) — `isAccessibilityElement = NO` dessus, `accessibilityElements` = array ordonné de `KXAxElement` (`UIAccessibilityElement` sous-classé).
- **Frame** : `accessibilityFrameInContainerSpace` (coords dans la view container, en **points**) — UIKit convertit tout seul en écran. On divise les bounds pixel par `scale` à `sync_begin`.
- **Keyed reuse** : pool `ident → KXAxElement` ; sync_item réutilise si présent, compare-and-set sur label/hint/traits/frame → `mutated` ; sync_end prune les idents absents et poste LayoutChanged/ScreenChanged.

## Table role → traits (conforme contrat)

| role zig | traits | isAccessibilityElement |
|---|---|---|
| generic | StaticText | oui |
| button | Button | oui |
| checkbox | Button (+Selected si SELECTED) | oui |
| slider | Adjustable | oui |
| textfield | None | **oui** (le label fait la valeur) |
| list | None | **non** (container muet) |
| listitem | Button si FOCUSABLE sinon StaticText | oui |
| heading | Header | oui |
| group | None | non |

flags : DISABLED→NotEnabled, FOCUSED→élément passé à LayoutChanged, SELECTED→+Selected.

## Vérification réelle (log + JSON)

- 39 éléments énumérés (40 avec le divider — filtré côté zig : label vide + non focusable + group ⇒ stop muet VoiceOver).
- Traits mesurés : Header `0x10000`, Button `0x1`, Adjustable `0x1000`, StaticText `0x40`, textfield `0x0`+element.
- Mutation : drag réel (#0→#14-#27) → mêmes idents, labels mis à jour en place (`Piste #14`…) → LayoutChanged reposté.
- Activate : `accessibilityActivate()` (trait Button) → cb zig → tap synthétique down/up au centre → `onAdd100` exécuté (chaine complète prouvée).
- VoiceOver sim non pilotable depuis l'hôte → **fallback contractuel** : dump programmatique (`kx_a11y_debug_dump`) qui énumère `view.accessibilityElements` (frames/labels/traits) + appelle `accessibilityActivate()`. C'est exactement le chemin qu'emprunte VoiceOver.

## Pièges iOS (consignés)

1. **`UIAccessibilityElement init` interdit** : `[[KXAxElement alloc] init]` jette `NSInvalidArgumentException 'Use initWithAccessibilityContainer:'`. Toujours `initWithAccessibilityContainer:`.
2. **`view.window == nil` au boot** : la SDLView n'est chaînée à sa UIWindow qu'après le premier runloop pass — présents avant = pixels perdus (voir k3-ios.md, sonde `kx_ios_window_mapped`).
3. **pt vs px** : zig parle pixels (1206×2622), UIKit attend des **points** → `bounds ÷ scale` avant affectation, jamais après.
4. **Réutilisation keyed = label compare-and-set** : même node* ⇒ même ident ⇒ même élément ; mettre à jour via `isEqualToString:` (copie NSString immédiate — jamais retenir le `const char*` zig, il vit dans un buffer réutilisé).
5. **`list` container = non-element** : `accessibilityElements` aplatit déjà — un élément 'list' rajouterait un stop muet ; le conteneur est transparent pour VoiceOver.
6. **Sync chaque tick** (pas seulement post-draw) : le scroll LazyList rematérialise pendant `draw()` ; la sync du même tick voit l'état à jour. Le coût est nul : compare-and-set no-op si rien n'a bougé.
7. **`--frames N` ne quitte pas** : UIApplicationMain garde le runloop — `simctl terminate` obligatoire entre runs (deux instances concurrentes = drags/dumps sur la mauvaise).
8. **`accessibilityElementsHidden` vs filtrage zig** : on préfère ne PAS émettre l'item (divider décoratif) plutôt que de le cacher — un élément caché consomme quand même un arrêt sur certains gestes.
9. **Ordre = ordre visuel** : `accessibilityElements` est parcouru dans l'ordre du tableau — le DFS de `collectSemantics` (top→down) est exactement celui attendu ; ne pas trier par y/x (les overlays casseraient l'ordre logique).
10. **Main-thread only** : sync + notifications sur le thread UIKit ; le tick zig tourne déjà sur le main thread (SDL callbacks iOS).

## Fichiers

- `kx_skia/src/kx_a11y_ios.mm` — impl (KXAxElement + KXAxState + sync_* + action_handler + helpers debug).
- `kx_skia/include/kx_skia.h` — section contrat ajoutée (diff dans results/k4-ios.diff).
- `gallery/main.zig` — `installA11y`, `syncA11y` (collectSemantics → sync_*), `a11yAction` (cb → tap synthétique), args `--a11y`/`--a11y-at N` (dump auto, re-dump toutes les 6s pour la vérif de mutation).
- `results/k4-ios.json`, `results/k4final.log`, `results/k4-sim.png`, `results/k4-ios.diff`.
