# A11Y-BRIDGES — arbre sémantique propre + ponts par plateforme (décision: maison)

## Forme commune (gelée)

Le host pousse une LISTE PLATE de nodes par cycle :

    sync_begin(view, scale) -> N x sync_item(view, ident, parent_ident,
        role, label, hint, x,y,w,h, flags) -> sync_end(view)

- `ident` = pointeur node* (clé de réutilisation côté shim, jamais déréférencé)
- `parent_ident` = 0 pour la racine
- `role` = enum 0..8 (generic button checkbox slider textfield list listitem
  heading group)
- `flags` = DISABLED|FOCUSABLE|FOCUSED|SELECTED (1/2/4/8)
- bounds = px / scale, flip-Y si !isFlipped (Apple)
- sync_end retourne 1 si l'arbre a muté -> le shim poste la notif de layout
  de la plateforme; change de focus -> notif focus.
- Zig: `ui.pushA11y(view, scale, root, alloc)` + `host.syncA11y(root,alloc)`
  + flag `sem_dirty` côté app (mutation -> re-push; le shim déduplique).

C'est le meme push-based contract partout — seul le shim change.

## Etat par pont

| Pont | Statut | Fichier | Notes |
|---|---|---|---|
| Web ARIA | DONE (lecture+actions+focus) | gallery wasm (JS glue) | DOM invisible positionne, roles natifs, reuse-par-index (focus retenu), el.click()/Enter/Espace -> gallery_tap -> vrai dispatch |
| macOS NSAccessibility | DONE | kx_skia/src/kx_a11y.mm | rebuild-reuse par node*, class_addMethod hittest (jamais swizzle), frameInParentSpace relatif au PARENT AX |
| Android TalkBack | DONE | platform/android/{java,jni} | KxA11yProvider (AccessibilityNodeProvider push-fed via statiques) + KxSurface + glue JNI kx_a11y_sync_* canonique ; TYPE_WINDOW_CONTENT_CHANGED/VIEW_FOCUSED ; ACTION_CLICK -> nativePerformAction -> g_a11y_cb -> marshal thread SDL ; uiautomator dump + logcat en preuve |
| iOS UIAccessibility | DONE | kx_skia/src/kx_a11y_ios.mm | KXAxElement (UIAccessibilityElement) pool keyed node*, traits role-map, activate/increment/decrement -> cb ; frameInContainerSpace (points, UIKit convertit ecran) ; pas de hittest custom |
| Windows UIA | DONE | kx_skia/src/kx_a11y_win.cpp | Simple+Fragment+FragmentRoot+SelectionItemPattern ; WndProc subclass SetWindowLongPtr ; pieges : mutex relache avant UiaReturnRawElementProvider, hwnd fragment-root seul ; 37 noeuds verifies VisualUIAVerifyNative |
| Linux AT-SPI | DONE | kx_skia/src/kx_a11y_linux.cpp | sd-bus via dlopen (zero dep build) ; fallback vtables Accessible/Component/Action sur prefix accessible + Application sur root ; Embed((so)) -> registryd ; verif busctl : tree/roles/names/extents/states exacts + DoAction -> SELECTED allume (mutation reelle) |

## Android — spec du shim (pour l'enfant)

- Java : classe `KxA11yProvider extends AccessibilityNodeProvider` tenue par
  la SurfaceView SDL ; `setAccessibilityDelegate`/`setImportantForAccessibility(YES)`.
- ABI C cote shim : idem kx_a11y_* mais `view` = jobject SurfaceView.
- sync_begin : snapshot des nodes courants ; sync_item : map role->className
  android ("android.widget.Button" etc), contentDescription = label(+hint),
  boundsInScreen = rect px (Android = coords ecran, PAS de flip ni scale —
  vue = plein ecran, surface origin = window origin), flags -> enabled/
  focusable/focused/selected + checkable/checked pour checkbox/slider.
- node ids : entier stable par node* (map pointer->int cote shim; id 0 = root).
- parent linkage : setParent(source,parent) + addChild dans les infos.
- sync_end : sendAccessibilityEvent TYPE_WINDOW_CONTENT_CHANGED si mute,
  TYPE_VIEW_FOCUSED/TYPE_VIEW_SELECTED sur delta focus.
- performAction : ACTION_CLICK -> callback JNI -> host dispatch tap au
  centre du node (reutilise ui.hit).
- Verification : uiautomator dump + TalkBack log (l'enfant a deja prouve que
  TalkBack REEL interroge le provider — instrumenter createNodeInfo).

## iOS — spec

- Copie de kx_a11y.mm : NSAccessibilityElement -> UIAccessibilityElement
  (UIKit). Pas d'equivalent accessibilityHitTest custom : iOS fait le hit
  naturellement (elements exposes = UIAccessibilityElement avec frame
  en coords ecran absolues). accessibilityElements sur la view SDL
  (UIView) retourne la liste triee — reuse keyed by node* identique.
- Notifs : UIAccessibilityLayoutChangedNotification /
  UIAccessibilityScreenChangedNotification.

## Linux AT-SPI — implémenté (kx_a11y_linux.cpp)

Option (a) retenue et faite : sd-bus chargé par dlopen (libsystemd.so.0,
runtime présent partout) + types sd-bus déclarés à la main — zéro dep build.
Fichier ~850 lignes, aucun import Skia.

**Contrat bus (vérifié live contre un vrai at-spi2-registryd) :**
- Adresse : `AT_SPI_BUS_ADDRESS` env → `sd_bus_set_address` +
  `sd_bus_set_bus_client(bus,1)` + `sd_bus_start`. Le set_bus_client est
  OBLIGATOIRE : sans lui start ouvre la socket sans handshake Hello →
  ECONNRESET (mesuré).
- Enregistrement : `org.a11y.atspi.Socket.Embed("(so)", uname, ROOT_PATH)`
  sur `/org/a11y/atspi/accessible/root` du service `org.a11y.atspi.Registry`.
  Réponse `(so)` = racine registry. Un appel à signature fausse peut TUER
  registryd (Connection reset by peer).
- Objets : root application sur `/org/a11y/atspi/accessible/root`,
  enfants `/org/a11y/atspi/accessible/node<i>` — servis par 3 vtables
  FALLBACK (Accessible+Component+Action) sur le prefix accessible + 1 vtable
  Application sur root. find_object retourne null=racine, -1=pas à nous.
- Actions uniquement sur roles actionnables (button/checkbox/slider/listitem)
  — findAction renvoie 0 sinon → ATs ne voient pas l'interface.

**Pièges ABI sd-bus (mesurés) :**
- `sd_bus_get_unique_name(bus, const char**)` retourne int + out-param —
  PAS un const char* (segfault sinon).
- `sd_bus_vtable` : bitfield `uint8_t type:8 + uint64_t flags:56` = uint64
  header ; entry START exige `.x.start = { element_size=sizeof(vtable),
  features=1 (_SD_BUS_VTABLE_PARAM_NAMES), vtable_format_reference=
  &sd_bus_object_vtable_format }` — le format_reference est un GLOBAL
  exporté à résoudre par dlsym ; absent → add_fallback_vtable EINVAL
  silencieux → "Unknown object" partout.
- `sd_bus_error` : ne jamais free(name)/free(message) séparément — name
  pointe DANS le buffer message → sd_bus_error_free(&e).
- Containers dans `sd_bus_message_append` variadique non supportés →
  open_container('a',"(so)") / ('r',"so") pour GetChildren/GetApplication.
- Events `siiva{sv}` : StateChanged("focused"/"selected"/"checked") +
  ChildrenChanged("add") émis à chaque sync mutée.
- Draining : `kx_a11y_pump()` = boucle sd_bus_process non bloquante, appelée
  chaque host.step (Linux uniquement, comptime-gated).

**États/rôles :** enum compilés depuis les headers libatspi 2.44 (valeurs
dans SESSION-STATE / mémoire). Map kx : button→43 PUSH_BUTTON, checkbox→7,
slider→51, textfield→79 ENTRY, list→31, listitem→32, heading→83,
group→99 GROUPING, racine→75 APPLICATION. GetState = `au` 2×u32.

**Vérif (busctl, live)** : Embed OK → GetChildren root→7, list→11
(virtualisation visible), GetRole/GetRoleName/Name/exacts, GetExtents
bounds réelles, GetState ENABLED|OPAQUE|SENSITIVE|SHOWING|VISIBLE|
SELECTABLE, DoAction(listitem)→b true→GetState +SELECTED.

## Actions (contrat étendu, gelé)

- `kx_a11y_set_action_handler(view, cb(ctx, node_ident, action), ctx)` —
  enregistré une fois au init. action 0 = press/activate, 1/2 = inc/dec
  (slider, optionnel). ident = le pointeur passé à sync_item, JAMAIS
  déréférencé côté shim.
- Zig : `host.setA11yActionHandler(cb, ctx)` → trampoline ident→*ui.Node
  → handler app. Gallery : a11yPress = tap down/up au centre des bounds
  (vrai chemin dispatch, pas un callback direct).
- Règle : l'activation rejoue le CHEMIN d'input réel (hit+focus+scrollable),
  pas un "invoke handler" — focus/scroll restent cohérents.
- Statut : ABI + Zig faits ; shims par plateforme en cours (macOS, Android,
  web déjà livré via gallery_tap).

## Notifications par plateforme (cheat sheet)

- macOS : NSAccessibilityLayoutChangedNotification / FocusedUIElementChanged
- iOS : UIAccessibilityLayoutChanged / ScreenChanged
- Android : AccessibilityEvent WINDOW_CONTENT_CHANGED / VIEW_FOCUSED
- Windows : UiaRaiseAutomationEvent / UiaRaiseAutomationPropertyChangedEvent
  (StructureChanged) / UiaRaiseFocusChangedEvent
- Linux : object:state-changed:focused, object:children-changed (D-Bus signal)
- Web : aucune — le DOM live suffit.
