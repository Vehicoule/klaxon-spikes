# Pont a11y UIA — Windows x64 (klaxon/k3-gallery)

## Architecture

```
zig ui.pushA11y(collectSemantics → 30 items)
  → kx_a11y_sync_begin/item/end  (kx_a11y_win.cpp)
      KxBridge (par HWND) : by_ident{node* → KxProvider}, seen, root synthétique
      sync_item : rebuild-with-reuse keyed by node* (provider réutilisé si même ident)
      sync_end  : pruneUnseen + UiaRaiseAutomationEvent(StructureChanged|
                  LayoutInvalidated) + delta focus → HasKeyboardFocus
  → KxUiaWndProc (SetWindowLongPtrW(GWLP_WNDPROC) — sous-classe le WndProc SDL)
      WM_GETOBJECT/UiaRootObjectId → lazy-create root →
      UiaReturnRawElementProvider(hwnd,w,l,root)
```

Chaque `KxProvider` implémente `IRawElementProviderSimple + Fragment +
FragmentRoot + ISelectionItemProvider` (le dernier gated `role==6` listitem).
Root synthétique = provider `is_root_` séparé, `Pane`/`kx-0`, enfants = les items
`parent_ident==0`.

- rôles → ControlType : button/checkbox/slider/edit/list/listitem/heading
  (Group + LocalizedControlType "heading")/group/generic
- bounds client px → `ClientToScreen` (nœuds), `GetClientRect+MapWindowPoints`
  (root) → `BoundingRectangle`
- flags → `IsEnabled`, `IsKeyboardFocusable`, `HasKeyboardFocus`,
  `SelectionItemProvider.IsSelected`
- `GetRuntimeId` = `{UiaAppendRuntimeId, rid}` ; `ProviderOptions =
  ServerSideProvider` ; `AutomationId` = `kx-N`
- hit-test : `FragmentRoot.ElementProviderFromPoint` → nœud le plus profond
  contenant le point

## Deux bugs de merge UIA rencontrés (documentés pour les autres plateformes)

1. **Mutex tenu pendant `UiaReturnRawElementProvider`** — l'appel rentre dans
   nos méthodes (`Navigate`, `get_ProviderOptions`) qui reprennent `g_mtx` →
   self-deadlock du wrap serveur → Windows retombe sur un **proxy MSAA**
   (`Main:Nested[Annotation…MSAA]` dans ProviderDescription). Fix : relâcher le
   lock AVANT l'appel.
2. **`NativeWindowHandle`/`HostRawElementProvider` renvoyés sur les nœuds
   enfants** — la couche de merge ré-injecte les providers HWND+NonClient dans
   CHAQUE nœud → la title bar devient enfant de nos items + cycle infini
   parent/enfant (dump à 500+ nœuds en spirale). Fix : hwnd host + propriété
   `UIA_NativeWindowHandlePropertyId` **fragment-root uniquement**.

## Vérif (galerie dawn-d3d12, hwnd 0x150344, driver WARP)

- `uia_dump.exe` (mini-client `AutomationElement.FromHandle`+RawViewWalker) :
  **37 nœuds** — `[1] Pane "Klaxon Gallery"` Main(parent link):Unidentified
  Provider → merge natif OK, pas de fallback MSAA. Enfants : title
  bar/System/Min/Max/Close (NonClient) + heading/group/button/checkbox/
  slider/edit/group/list + ListItem "Piste #0-#10" → group chacun.
  `uia_dump_state0.txt`.
- **VisualUIAVerifyNative + Inspect** (SDK Windows) : arbre complet visible
  sous `pane "Klaxon Gallery" "kx-0"`, AutomationIds `kx-N`, LocalizedControlType
  `heading`/`list item`/`edit`… — `uiaverify_tree.png`,
  `uiaverify_heading_props.png`.
- **Hit-test** : Inspect hover → `group "Piste #5" "kx-21"` —
  `inspect_hover_piste.png` (ElementProviderFromPoint OK).
- **Sync live** : scroll molette réel → `uia_dump_scrolled.txt` montre
  `Piste #1-#11` (virtualisation LazyList reflétée, reuse-by-ident OK).

## Livrables

- `shim/kx_a11y_win.cpp` (~670 lignes) — provider complet + subclass
- `uia/uia_dump.cpp` + `build/uia_dump.exe` — mini-client vérif standalone
- `scripts/build_shim.bat` (TU a11y compilé SANS `WIN32_LEAN_AND_MEAN`,
  libs ole32/oleaut32/uiautomationcore/user32)
- `zig-*.patch` — diff zig : `kx.zig` (3 externs), `ui.zig` (`a11yBridgeRole`+
  `pushA11y`, FBA 64K, bufPrintSentinel), `host.zig` (`syncA11y` gated
  `comptime windows`), `gallery/main.zig` (appel sur `.drew`)
- `uia-verif.json`, dumps, screenshots, ce doc

## Limites connues

- Pas de patterns Invoke/Value/Text/RangeValue — spec gelée = props +
  SelectionItem uniquement.
- `SetWindowSubclass` indisponible proprement sous SDL → `SetWindowLongPtr`
  utilisé (équivalent pour un WndProc appartenant à notre processus ; SDL garde
  `CallWindowProc(old)` pour le reste).
- Sous-classe + provider liés au HWND par sync_begin — une seule vue a11y
  par HWND.
