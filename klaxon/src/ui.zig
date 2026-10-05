// ui.zig — arbre UI retenu v1 sur kx : layout row/column, dessin, hit-test.
// Modèle : un Node a une taille d'axe (px ou poids), des enfants (row|column),
// un fond/paint optionnel, un texte optionnel (kx_para retenu), un handler
// pointer optionnel. Le layout calcule les bounds une fois par resize/relayout.
const std = @import("std");
const kx = @import("kx.zig");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }
};

pub const Axis = enum { row, column, leaf };

pub const TextAlign = enum { left, center, right };

/// Taille le long de l'axe du parent : px fixe ou poids flex.
pub const Size = union(enum) {
    px: f32,
    weight: f32, // part de l'espace restant proportionnelle au poids
};

pub const Paint = struct {
    /// Fond : rrect dessiné dans les bounds (paint optionnel, rx=0 → rect).
    fill: ?*kx.Paint = null,
    rx: f32 = 0,
    /// Bordure (stroke) optionnelle.
    stroke: ?*kx.Paint = null,
    /// Paragraphe retenu dessiné centré-verticalement, x aligné via `text_align`.
    text: ?*kx.Para = null,
    text_align: TextAlign = .left,
    /// Dessin custom (cercles, icônes…), appelé avec clip sur les bounds.
    /// ctx = node.userdata (état widget atteignable sans global).
    custom: ?*const fn (t: ?*kx.Target, b: Rect, ctx: ?*anyopaque) void = null,
    /// Anneau de focus (stroke ~2px, posé par l'app) — dessiné 1px à
    /// l'intérieur des bounds quand `node.focused` (survit au clip parent).
    focus_ring: ?*kx.Paint = null,
};

/// Accessibilité maison (décision 2026-10-04 — AccessKit écarté car Rust).
/// Champ parallèle à paint ; l'arbre sémantique plat est extrait par
/// `collectSemantics` puis traduit par les ponts plateforme (ARIA web,
/// AccessibilityNodeProvider Android, UIAccessibility iOS, UIA Win, AT-SPI).
pub const Role = enum {
    none,
    text,
    button,
    toggle,
    slider,
    text_field,
    list,
    list_item,
    image,
    header,
    divider,
};

pub const Semantics = struct {
    role: Role = .none,
    label: []const u8 = "",
    hint: []const u8 = "",
    focusable: bool = false,
    disabled: bool = false,
};

/// État de défilement d'un conteneur (column v1). `scroll != null` sur un
/// Node ⇒ layout décale les enfants de -offset et draw les clippe au
/// viewport. `fixed_content` : LazyList connaît sa taille sans matérialiser.
pub const Scroll = struct {
    offset: f32 = 0,
    viewport: f32 = 0, // longueur visible sur l'axe (fixé par layout)
    content: f32 = 0,  // longueur totale du contenu
    fixed_content: bool = false,
    drag: ?f32 = null, // position du drag en cours (null = pas de drag)

    pub fn maxOffset(s: *const Scroll) f32 {
        return @max(0, s.content - s.viewport);
    }
    /// Renvoie true si l'offset a bougé (appelant → dirty + resync).
    pub fn setOffset(s: *Scroll, v: f32) bool {
        const c = @min(@max(0, v), s.maxOffset());
        if (c == s.offset) return false;
        s.offset = c;
        return true;
    }
    pub fn scrollBy(s: *Scroll, dy: f32) bool {
        return s.setOffset(s.offset + dy);
    }
    /// Défile le minimum pour rendre [r_min, r_max] (coords contenu, axe du
    /// scroll) visible, moins `bottom_inset` px réservés en bas (ex. clavier
    /// IME : Android #13166 ne signale RIEN à SDL — l'OS pan la fenêtre et le
    /// champ peut rester 100 % masqué ; le framework doit scroller lui-même
    /// avec l'inset lu via WindowInsets.ime()). Renvoie true si l'offset bouge.
    pub fn ensureVisible(s: *Scroll, r_min: f32, r_max: f32, bottom_inset: f32) bool {
        const vis = s.viewport - @max(0, bottom_inset);
        if (vis <= 0) return false;
        if (r_max - r_min >= vis) return s.setOffset(r_min); // plus grand que la zone : aligner le haut
        if (r_min < s.offset) return s.setOffset(r_min);
        if (r_max > s.offset + vis) return s.setOffset(r_max - vis);
        return false;
    }
};

pub const Node = struct {
    axis: Axis = .leaf,
    size: Size = .{ .weight = 1 },
    // Hauteur transverse (column : largeur px du contenu ; row : hauteur px).
    // 0 = remplit l'espace transversal disponible.
    cross: f32 = 0,
    pad: f32 = 0,
    gap: f32 = 0,
    paint: Paint = .{},
    children: []const *Node = &.{},
    on_pointer: ?*const fn (n: *Node, ev: PointerEvent) void = null,
    bounds: Rect = .{},
    /// taille intrinsèque pour les leafs (px le long de l'axe si size=.px
    /// non donné) — utilisé quand size = .{ .px = v }.
    intrinsic: f32 = 0,
    /// Conteneur scrollable (non-null ⇒ décalage + clip des enfants).
    scroll: ?*Scroll = null,
    /// Sémantique a11y (role=.none ⇒ ignoré par collectSemantics).
    semantics: Semantics = .{},
    /// Focus clavier courant (posé par Focus.set — anneau si focus_ring).
    focused: bool = false,
    /// Sélection courante (posée par l'app — expose A11Y_SELECTED au lecteur
    /// d'écran, ex. item de liste sélectionné).
    selected: bool = false,
    /// Dispatch clavier quand le node détient le focus (Enter/Space/flèches/
    /// touches d'édition). Renvoie true si consommé (→ l'app re-dirty).
    on_key: ?*const fn (n: *Node, key: u32, mod: u16) bool = null,
    /// État opaque du widget propriétaire (Button*, Toggle*…) — transmis
    /// à on_pointer et à paint.custom. L'app le pose via widget.bind().
    userdata: ?*anyopaque = null,

    pub fn draw(n: *const Node, t: ?*kx.Target) void {
        const b = n.bounds;
        if (b.w <= 0 or b.h <= 0) return;
        if (n.paint.fill) |p| {
            if (n.paint.rx > 0)
                _ = kx.kx_canvas_draw_rrect(t, b.x, b.y, b.w, b.h, n.paint.rx, n.paint.rx, p)
            else
                _ = kx.kx_canvas_draw_rect(t, b.x, b.y, b.w, b.h, p);
        }
        if (n.paint.stroke) |p| {
            _ = kx.kx_canvas_draw_rrect(t, b.x, b.y, b.w, b.h, n.paint.rx, n.paint.rx, p);
        }
        if (n.paint.custom) |f| {
            _ = kx.kx_canvas_save(t);
            _ = kx.kx_canvas_clip_rect(t, b.x, b.y, b.w, b.h);
            f(t, b, n.userdata);
            _ = kx.kx_canvas_restore(t);
        }
        if (n.focused) {
            if (n.paint.focus_ring) |p| {
                // anneau 1px rentré — l'anneau externe serait clippé par un
                // parent scrollable ; ici il survit dans tous les conteneurs.
                const rx = if (n.paint.rx > 1) n.paint.rx - 1 else 0;
                _ = kx.kx_canvas_draw_rrect(t, b.x + 1, b.y + 1, b.w - 2, b.h - 2, rx, rx, p);
            }
        }
        if (n.paint.text) |para| {
            const ph = kx.kx_para_height(para);
            const pw = kx.kx_para_max_intrinsic_width(para);
            const tx = switch (n.paint.text_align) {
                .left => b.x,
                .center => b.x + @max(0, (b.w - pw) / 2),
                .right => b.x + @max(0, b.w - pw),
            };
            _ = kx.kx_para_draw(para, t, tx, b.y + @max(0, (b.h - ph) / 2));
        }
        if (n.scroll != null) {
            // Conteneur scrollable : les enfants débordent le viewport —
            // clip obligatoire (sinon ils peignent hors des bounds).
            _ = kx.kx_canvas_save(t);
            _ = kx.kx_canvas_clip_rect(t, b.x, b.y, b.w, b.h);
            for (n.children) |c| c.draw(t);
            _ = kx.kx_canvas_restore(t);
        } else {
            for (n.children) |c| c.draw(t);
        }
    }

    /// Hit-test descendant : dernier (z-order haut) node dont les bounds
    /// contiennent le point et qui a un handler.
    pub fn hitTest(n: *Node, px: f32, py: f32) ?*Node {
        if (!n.bounds.contains(px, py)) return null;
        var i: usize = n.children.len;
        while (i > 0) {
            i -= 1;
            if (n.children[i].hitTest(px, py)) |h| return h;
        }
        return if (n.on_pointer != null) n else null;
    }
};

/// Navigation clavier : DFS des `semantics.focusable`, Tab/Shift-Tab wrap.
/// `current` pointe un node de l'arbre ; `focused` reflète l'état pour draw
/// et pour collectSemantics (aria/AT).
pub const Focus = struct {
    current: ?*Node = null,

    pub fn set(f: *Focus, n: ?*Node) void {
        if (f.current == n) return;
        if (f.current) |c| c.focused = false;
        f.current = n;
        if (n) |nn| nn.focused = true;
    }

    /// dir=+1 (Tab) / -1 (Shift+Tab) : avance/recule dans l'ordre DFS, wrap
    /// aux extrémités ; sans focus courant : dir≥0 → premier, <0 → dernier.
    /// Renvoie le node désormais focusé (null si aucun focusable).
    pub fn move(f: *Focus, root: *Node, dir: i32, alloc: std.mem.Allocator) ?*Node {
        var list = std.ArrayList(*Node).empty;
        defer list.deinit(alloc);
        collectFocusable(root, &list, alloc);
        const items = list.items;
        if (items.len == 0) {
            f.set(null);
            return null;
        }
        const n: i64 = @intCast(items.len);
        var idx: i64 = -1;
        if (f.current) |c| {
            for (items, 0..) |it, i| {
                if (it == c) {
                    idx = @intCast(i);
                    break;
                }
            }
        }
        const next: usize = if (idx < 0)
            @intCast(if (dir >= 0) @as(i64, 0) else n - 1)
        else
            @intCast(@mod(idx + dir, n));
        f.set(items[next]);
        return f.current;
    }
};

fn collectFocusable(n: *Node, out: *std.ArrayList(*Node), alloc: std.mem.Allocator) void {
    if (n.semantics.focusable) out.append(alloc, n) catch return;
    for (n.children) |c| collectFocusable(c, out, alloc);
}

pub const PointerEvent = struct {
    kind: enum { down, up, move, wheel },
    x: f32,
    y: f32,
    button: u8 = 0,
    // wheel : delta en px, dy > 0 = contenu descend (offset augmente).
    dx: f32 = 0,
    dy: f32 = 0,
};

/// Dispatch wheel/drag aux ancêtres scrollables — le plus profond gagne.
/// À appeler AVANT dispatch() : le drag-scroll prime sur le tap des items
/// (v1 sans geste-arbitrage ; un down revendique le scroll même sans bouger,
/// dispatch() délivre quand même le tap au handler de l'item).
pub fn dispatchScrollable(n: *Node, ev: PointerEvent) ?*Node {
    if (!n.bounds.contains(ev.x, ev.y)) return null;
    var i: usize = n.children.len;
    while (i > 0) {
        i -= 1;
        if (dispatchScrollable(n.children[i], ev)) |h| return h;
    }
    const s = n.scroll orelse return null;
    switch (ev.kind) {
        .wheel => {
            if (s.scrollBy(ev.dy)) return n;
        },
        .down => {
            s.drag = ev.y;
            return n;
        },
        .move => {
            if (s.drag) |last| {
                _ = s.scrollBy(last - ev.y); // tirer vers le bas = remonter
                s.drag = ev.y;
                return n;
            }
        },
        .up => {
            s.drag = null;
            return n;
        },
    }
    return null;
}

// ---------------------------------------------------------------------------
// Arbre sémantique — extraction plate commune à tous les ponts plateforme.
// ---------------------------------------------------------------------------
pub const SemItem = struct {
    node: *const Node,
    role: Role,
    label: []const u8,
    hint: []const u8,
    bounds: Rect,
    depth: usize,
    parent: ?usize, // index dans la liste aplatie
    disabled: bool,
    focusable: bool,
    /// focus clavier courant (AT : aria-focused/état FOCUSED natif).
    focused: bool,
    /// sélection courante (AT : aria-selected/état SELECTED natif).
    selected: bool,
};

/// Aplatit les nodes sémantiques dans `out` (ordre DFS, parent = index
/// du SemItem ancêtre le plus proche ayant un role != .none).
pub fn collectSemantics(n: *const Node, alloc: std.mem.Allocator, out: *std.ArrayList(SemItem), parent: ?usize) !void {
    var idx = parent;
    if (n.semantics.role != .none) {
        idx = out.items.len;
        try out.append(alloc, .{
            .node = n,
            .role = n.semantics.role,
            .label = n.semantics.label,
            .hint = n.semantics.hint,
            .bounds = n.bounds,
            .depth = if (parent) |p| out.items[p].depth + 1 else 0,
            .parent = parent,
            .disabled = n.semantics.disabled,
            .focusable = n.semantics.focusable,
            .focused = n.focused,
            .selected = n.selected,
        });
    }
    for (n.children) |c| try collectSemantics(c, alloc, out, idx);
}

/// Pousse l'arbre plat vers le pont NSAccessibility (kx_a11y.mm — macOS/iOS).
/// `view` = NSView hôte (sdl.MetalView), `scale` = px physiques / points.
/// Appel gated comptime Apple côté host — aucun extern n'existe ailleurs.
pub fn pushA11y(view: ?*anyopaque, scale: f64, root: *const Node, alloc: std.mem.Allocator) !void {
    var items: std.ArrayList(SemItem) = .empty;
    defer items.deinit(alloc);
    try collectSemantics(root, alloc, &items, null);
    if (kx.kx_a11y_sync_begin(view, scale) != 0) return;
    for (items.items) |it| {
        const role: kx.A11yRole = switch (it.role) {
            .button => .button,
            .toggle => .checkbox,
            .slider => .slider,
            .text_field => .textfield,
            .list => .list,
            .list_item => .listitem,
            .header => .heading,
            // text/image/divider : pas de rôle dédié dans l'ABI → group
            else => .generic,
        };
        // Nœud purement décoratif (label vide + non interactif + rôle
        // générique) → pas d'arrêt AT : le lecteur ferait un stop muet
        // (filtré en amont — mesuré utile sur le divider iOS).
        if (it.label.len == 0 and !it.focusable and role == .generic) continue;
        var flags: c_uint = 0;
        if (it.disabled) flags |= kx.A11Y_DISABLED;
        if (it.focusable) flags |= kx.A11Y_FOCUSABLE;
        if (it.focused) flags |= kx.A11Y_FOCUSED;
        if (it.selected) flags |= kx.A11Y_SELECTED;
        // label/hint : sentinelles requises (le shim copie côté ObjC)
        const lz = try alloc.dupeSentinel(u8, it.label, 0);
        defer alloc.free(lz);
        const hz = try alloc.dupeSentinel(u8, it.hint, 0);
        defer alloc.free(hz);
        const parent: ?*const anyopaque = if (it.parent) |p| items.items[p].node else null;
        _ = kx.kx_a11y_sync_item(view, it.node, parent, @intFromEnum(role), lz, hz, it.bounds.x, it.bounds.y, it.bounds.w, it.bounds.h, flags);
    }
    _ = kx.kx_a11y_sync_end(view);
}

// ---------------------------------------------------------------------------
// LazyList — liste virtualisée à items uniformes (v1, column seule).
// Seuls les items visibles sont matérialisés dans `slots` (mémoire fixe).
// ---------------------------------------------------------------------------
pub const LazyList = struct {
    count: usize,
    item_extent: f32, // hauteur px par item (uniforme v1)
    gap: f32 = 0,
    /// Remplit `slot` pour l'item `index`. Le framework force ensuite
    /// slot.size = .{ .px = item_extent }.
    builder: *const fn (slot: *Node, index: usize, ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
    scroll: Scroll = .{ .fixed_content = true },
    /// Fenêtre recyclée, fournie par l'app : assez grande pour couvrir
    /// le viewport + overscan (viewport/item_extent + 2 typiquement).
    slots: []Node,
    /// Pointeurs des children : longueur = slots.len + 1. L'index 0 est
    /// réservé au spacer virtuel qui repousse la fenêtre à sa position
    /// de contenu absolue (first × span).
    slot_ptrs: []*Node,
    /// Node hôte à insérer dans l'arbre (scroll + column). Appeler
    /// `initNode()` une fois la LazyList à son adresse finale.
    host_node: Node = .{ .axis = .column },
    spacer: Node = .{}, // taille = first×span - gap, invisible (pas de paint)
    first: usize = 0,      // premier index matérialisé
    view_count: usize = 0, // slots utilisés
    /// true quand le viewport veut plus d'items que slots.len — l'app doit
    /// agrandir sa fenêtre (le bas du viewport reste vide sinon).
    saturated: bool = false,
    last_spacer: f32 = -1, // dernier spacer_px appliqué (détecte rebuild)

    /// Lie host_node.scroll à &scroll — requis avant tout usage.
    pub fn initNode(ll: *LazyList) void {
        ll.host_node.scroll = &ll.scroll;
        ll.host_node.gap = ll.gap;
        ll.scroll.content = @as(f32, @floatFromInt(ll.count)) * ll.item_extent +
            ll.gap * @as(f32, @floatFromInt(if (ll.count > 0) ll.count - 1 else 0));
    }

    /// Resynchronise la fenêtre matérialisée avec scroll.offset.
    /// Renvoie true si la fenêtre a changé (→ relayout du host_node).
    /// Viewport lu depuis host_node.bounds (layout précédent).
    pub fn syncWindow(ll: *LazyList) bool {
        const span = ll.item_extent + ll.gap;
        if (span <= 0 or ll.count == 0) {
            ll.host_node.children = &.{};
            return ll.view_count != 0;
        }
        const first_new: usize = @intFromFloat(@max(0, @floor(ll.scroll.offset / span)));
        const vp = @max(0, ll.host_node.bounds.h - 2 * ll.host_node.pad);
        const end_f = @ceil((ll.scroll.offset + vp) / span);
        const end_new: usize = @min(ll.count, @as(usize, @intFromFloat(@max(0, end_f))));
        const wanted = if (end_new > first_new) end_new - first_new else 0;
        ll.saturated = wanted > ll.slots.len;
        const cnt = @min(wanted, ll.slots.len);
        // Spacer = espace des items non matérialisés avant `first`, moins
        // le gap que le layout insère entre spacer et premier item réel.
        // first == 0 ⇒ pas de spacer (sinon item0 serait décalé d'un gap).
        const use_spacer = first_new > 0;
        const spacer_px = if (use_spacer) @as(f32, @floatFromInt(first_new)) * span - ll.gap else 0;
        if (cnt == ll.view_count and first_new == ll.first and ll.last_spacer == spacer_px) return false;
        ll.first = first_new;
        ll.view_count = cnt;
        ll.last_spacer = spacer_px;
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const slot = &ll.slots[i];
            slot.* = .{}; // recycle : état neuf à chaque matérialisation
            ll.builder(slot, first_new + i, ll.ctx);
            slot.size = .{ .px = ll.item_extent };
            ll.slot_ptrs[i + 1] = slot;
        }
        if (use_spacer) {
            ll.spacer = .{ .size = .{ .px = spacer_px } };
            ll.slot_ptrs[0] = &ll.spacer;
            ll.host_node.children = ll.slot_ptrs[0 .. cnt + 1];
        } else {
            ll.host_node.children = ll.slot_ptrs[1 .. cnt + 1];
        }
        return true;
    }

    /// Relayout du sous-arbre liste après syncWindow() (bounds déjà posés
    /// par le layout parent).
    pub fn relayout(ll: *LazyList) void {
        layout(&ll.host_node, ll.host_node.bounds);
    }

    /// Force la re-matérialisation au prochain syncWindow (changement de
    /// style, item_extent, données…).
    pub fn invalidate(ll: *LazyList) void {
        ll.view_count = 0;
    }
};

// ---------------------------------------------------------------------------
// TextField — modèle d'édition pur (caret, sélection, composition IME).
// Buffer fixe : pas d'allocateur, portable wasm. Le dessin (caret, surlignage,
// pré-edit souligné) et le mapping glyph↔x relèvent de kx_para côté app.
// ---------------------------------------------------------------------------
pub const TextField = struct {
    pub const CAP = 2048;
    buf: [CAP]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,  // octet — tête de sélection
    anchor: usize = 0, // octet — pied de sélection (= caret sans sélection)
    comp_start: usize = 0,
    comp_len: usize = 0, // zone de composition IME en cours
    focused: bool = false,
    /// Positionné par toute mutation (insert/move/compose) — l'app rebuild
    /// son para/caret-x puis le remet à false.
    dirty: bool = true,

    pub fn text(f: *const TextField) []const u8 {
        return f.buf[0..f.len];
    }
    pub fn hasSelection(f: *const TextField) bool {
        return f.caret != f.anchor;
    }
    fn selLo(f: *const TextField) usize {
        return @min(f.caret, f.anchor);
    }
    fn selHi(f: *const TextField) usize {
        return @max(f.caret, f.anchor);
    }

    fn splice(f: *TextField, at: usize, remove: usize, bytes: []const u8) void {
        if (f.len - remove + bytes.len > CAP) return; // refuse plutôt que tronquer
        std.mem.copyBackwards(u8, f.buf[at + bytes.len .. f.len - remove + bytes.len], f.buf[at + remove .. f.len]);
        @memcpy(f.buf[at .. at + bytes.len], bytes);
        f.len = f.len - remove + bytes.len;
    }

    /// Remplace la sélection (ou insère au caret) puis positionne le caret.
    pub fn insert(f: *TextField, bytes: []const u8) void {
        const lo = f.selLo();
        const hi = f.selHi();
        f.splice(lo, hi - lo, bytes);
        f.caret = lo + bytes.len;
        f.anchor = f.caret;
        f.comp_start = f.caret;
        f.comp_len = 0;
        f.dirty = true;
    }

    /// Composition IME : remplace la zone de composition courante.
    pub fn compose(f: *TextField, bytes: []const u8) void {
        // la sélection initiale devient la zone de composition
        if (f.hasSelection() and f.comp_len == 0) {
            f.comp_start = f.selLo();
            f.comp_len = f.selHi() - f.comp_start;
            f.caret = f.selHi();
            f.anchor = f.caret;
        }
        f.splice(f.comp_start, f.comp_len, bytes);
        f.comp_len = bytes.len;
        f.caret = f.comp_start + f.comp_len;
        f.anchor = f.caret;
        f.dirty = true;
    }

    /// Commit IME : remplace la composition puis la referme.
    pub fn commit(f: *TextField, bytes: []const u8) void {
        f.compose(bytes);
        f.comp_len = 0;
    }

    pub fn deleteBackward(f: *TextField) void {
        if (f.hasSelection()) {
            f.insert("");
        } else if (f.caret > 0) {
            const prev = prevBoundary(f.buf[0..f.caret]);
            f.splice(prev, f.caret - prev, "");
            f.caret = prev;
            f.anchor = prev;
            f.dirty = true;
        }
    }

    pub fn deleteForward(f: *TextField) void {
        if (f.hasSelection()) {
            f.insert("");
        } else if (f.caret < f.len) {
            const nxt = nextBoundary(f.buf[0..f.len], f.caret);
            f.splice(f.caret, nxt - f.caret, "");
            f.dirty = true;
        }
    }

    /// Déplacement UTF-8-safe (frontières de codepoints).
    pub fn moveCaret(f: *TextField, delta: i32, extend: bool) void {
        var c = f.caret;
        var d = delta;
        while (d < 0 and c > 0) : (d += 1) c = prevBoundary(f.buf[0..c]);
        while (d > 0 and c < f.len) : (d -= 1) c = nextBoundary(f.buf[0..f.len], c);
        f.caret = c;
        if (!extend) f.anchor = c;
        f.dirty = true;
    }
    pub fn setCaret(f: *TextField, pos: usize, extend: bool) void {
        f.caret = @min(pos, f.len);
        if (!extend) f.anchor = f.caret;
        f.dirty = true;
    }
    pub fn home(f: *TextField, extend: bool) void {
        f.setCaret(0, extend);
    }
    pub fn end(f: *TextField, extend: bool) void {
        f.setCaret(f.len, extend);
    }
    pub fn selectAll(f: *TextField) void {
        f.anchor = 0;
        f.caret = f.len;
    }
};

fn isCont(b: u8) bool {
    return (b & 0xC0) == 0x80;
}
fn prevBoundary(s: []const u8) usize {
    var i = s.len - 1;
    while (i > 0 and isCont(s[i])) i -= 1;
    return i;
}
fn nextBoundary(s: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < s.len and isCont(s[j])) j += 1;
    return j;
}

/// Layout un arbre dans `rect` selon l'axe du node.
/// Un node .leaf ou .row/.column sans enfants dimensionne son `intrinsic`
/// si size = .px explicite, sinon occupe la part allouée.
pub fn layout(n: *Node, rect: Rect) void {
    n.bounds = rect;
    const kids = n.children;
    if (kids.len == 0) return;
    const inner = Rect{
        .x = rect.x + n.pad,
        .y = rect.y + n.pad,
        .w = @max(0, rect.w - 2 * n.pad),
        .h = @max(0, rect.h - 2 * n.pad),
    };
    const horiz = n.axis == .row;
    const main_len = if (horiz) inner.w else inner.h;

    // Scroll : viewport connu = main_len ; les enfants partent de -offset.
    var shift: f32 = 0;
    if (n.scroll) |s| {
        s.viewport = main_len;
        shift = s.offset;
    }

    // Passe 1 : somme des poids et des px fixes.
    var total_w: f32 = 0;
    var fixed: f32 = 0;
    for (kids) |c| {
        switch (c.size) {
            .px => |v| fixed += v,
            .weight => |w| total_w += w,
        }
    }
    const gaps = n.gap * @as(f32, @floatFromInt(if (kids.len > 0) kids.len - 1 else 0));
    const free_space = @max(0, main_len - fixed - gaps);

    // Passe 2 : distribution.
    const start = if (horiz) inner.x else inner.y;
    var cursor: f32 = start - shift;

    for (kids) |c| {
        const share = switch (c.size) {
            .px => |v| v,
            .weight => |w| if (total_w > 0) free_space * (w / total_w) else 0,
        };
        const cross_len = if (c.cross > 0) @min(c.cross, if (horiz) inner.h else inner.w)
            else (if (horiz) inner.h else inner.w);
        const cross_off = ((if (horiz) inner.h else inner.w) - cross_len) / 2;
        const cb: Rect = if (horiz) .{
            .x = cursor,
            .y = inner.y + cross_off,
            .w = share,
            .h = cross_len,
        } else .{
            .x = inner.x + cross_off,
            .y = cursor,
            .w = cross_len,
            .h = share,
        };
        layout(c, cb);
        cursor += share + n.gap;
    }

    // Contenu réel consommé (sans le shift scroll : cursor - position de
    // départ - trailing gap). Un LazyList fige content lui-même (ses
    // enfants ne sont que la fenêtre matérialisée).
    if (n.scroll) |s| {
        if (!s.fixed_content) s.content = @max(0, cursor - (start - shift) - n.gap);
    }
}

/// Dispatch d'un événement pointer : retourne le node cible (ou null).
pub fn dispatch(root: *Node, ev: PointerEvent) ?*Node {
    const t = root.hitTest(ev.x, ev.y) orelse return null;
    t.on_pointer.?(t, ev);
    return t;
}

// ---------------------------------------------------------------------------
// Animation v1 — tween pure, pilotée par l'horloge host (host.dirty tant que
// `done` est faux). Pas de scheduler : l'app échantillonne `value(now)` par
// frame, exactement comme un style calculé.
// ---------------------------------------------------------------------------
pub const Ease = enum { linear, in_out, out_cubic };

/// Interpolation `from → to` sur `dur_us` microsecondes depuis `start_us`.
pub const Anim = struct {
    from: f32,
    to: f32,
    start_us: i64,
    dur_us: i64,
    ease: Ease = .in_out,

    pub fn init(now_us: i64, from: f32, to: f32, dur_us: i64) Anim {
        return .{ .from = from, .to = to, .start_us = now_us, .dur_us = @max(1, dur_us) };
    }

    /// t ∈ [0,1] clampé, easing appliqué.
    pub fn progress(a: Anim, now_us: i64) f32 {
        const t = @as(f32, @floatFromInt(now_us - a.start_us)) / @as(f32, @floatFromInt(a.dur_us));
        const c = @min(1, @max(0, t));
        return switch (a.ease) {
            .linear => c,
            .in_out => if (c < 0.5) 4 * c * c * c else 1 - std.math.pow(f32, -2 * c + 2, 3) / 2,
            .out_cubic => 1 - std.math.pow(f32, 1 - c, 3),
        };
    }

    pub fn value(a: Anim, now_us: i64) f32 {
        return a.from + (a.to - a.from) * a.progress(now_us);
    }

    pub fn done(a: Anim, now_us: i64) bool {
        return now_us - a.start_us >= a.dur_us;
    }
};

// ---------------------------------------------------------------------------
// Tests (zig test — ne touchent pas aux externs kx : compilation paresseuse)
// ---------------------------------------------------------------------------
const expect = std.testing.expect;
fn expectApprox(actual: f32, expected: f32, tol: f32) !void {
    if (@abs(actual - expected) > tol) {
        std.debug.print("expected {d} ±{d}, got {d}\n", .{ expected, tol, actual });
        return error.TestExpectedApprox;
    }
}

test "layout column : px fixes + poids partagent le reste" {
    var a: Node = .{ .size = .{ .px = 100 } };
    var b: Node = .{ .size = .{ .weight = 1 } };
    var c: Node = .{ .size = .{ .weight = 3 } };
    var root: Node = .{ .axis = .column, .pad = 10, .gap = 20, .children = &.{ &a, &b, &c } };
    layout(&root, .{ .x = 0, .y = 0, .w = 200, .h = 400 });
    // inner h = 380 ; fixed 100 ; gaps 40 ; free = 240 → b=60, c=180
    try expectApprox(a.bounds.y, 10, 0.001);
    try expectApprox(a.bounds.h, 100, 0.001);
    try expectApprox(b.bounds.y, 130, 0.001); // 10 + 100 + 20
    try expectApprox(b.bounds.h, 60, 0.001);
    try expectApprox(c.bounds.y, 210, 0.001); // 10 + 100 + 20 + 60 + 20
    try expectApprox(c.bounds.h, 180, 0.001);
    try expectApprox(c.bounds.w, 180, 0.001); // inner w
}

test "layout row : gap, cross centré, px vs weight" {
    var a: Node = .{ .size = .{ .px = 50 }, .cross = 20 };
    var b: Node = .{ .size = .{ .weight = 1 } };
    var root: Node = .{ .axis = .row, .pad = 0, .gap = 10, .children = &.{ &a, &b } };
    layout(&root, .{ .x = 0, .y = 0, .w = 310, .h = 100 });
    // a: w=50, cross 20 centré → y=40 ; b: w = 310-50-10 = 250
    try expectApprox(a.bounds.w, 50, 0.001);
    try expectApprox(a.bounds.h, 20, 0.001);
    try expectApprox(a.bounds.y, 40, 0.001);
    try expectApprox(b.bounds.x, 60, 0.001);
    try expectApprox(b.bounds.w, 250, 0.001);
}

var hits: usize = 0;
fn countHit(n: *Node, ev: PointerEvent) void {
    _ = n;
    _ = ev;
    hits += 1;
}

test "hitTest : descendant z-order, dernier gagne ; dispatch appelle le handler" {
    var back: Node = .{ .on_pointer = countHit };
    var top: Node = .{ .on_pointer = countHit };
    var dead: Node = .{}; // pas de handler → transparent pour le hit
    var root: Node = .{ .axis = .column, .children = &.{ &dead, &back, &top } };
    layout(&root, .{ .x = 0, .y = 0, .w = 100, .h = 300 });
    // dead [0,100), back [100,200), top [200,300)
    try expect(root.hitTest(50, 50) == null);
    try expect(root.hitTest(50, 150) == &back);
    try expect(root.hitTest(50, 250) == &top);
    try expect(root.hitTest(150, 50) == null); // hors bounds x
    hits = 0;
    try expect(dispatch(&root, .{ .kind = .down, .x = 50, .y = 250 }) == &top);
    try expect(hits == 1);
}

test "bounds.contains : bords exclus à droite/bas" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try expect(r.contains(10, 10));
    try expect(r.contains(109.9, 59.9));
    try expect(!r.contains(110, 30));
    try expect(!r.contains(50, 60));
}

test "Anim : clamp début/fin, value, done" {
    const a = Anim.init(1000, 0, 100, 1000); // start=1000µs, dur=1000µs → end=2000µs
    try expectApprox(a.value(500), 0, 0.001); // avant start → from
    try expectApprox(a.value(1000), 0, 0.001); // à start → from
    try expectApprox(a.value(2000), 100, 0.001); // à end → to
    try expectApprox(a.value(99999), 100, 0.001); // après → clampé
    try expect(!a.done(1999));
    try expect(a.done(2000));
}

test "Anim.linear : mid = milieu" {
    var a = Anim.init(0, 10, 20, 100);
    a.ease = .linear;
    try expectApprox(a.value(50), 15, 0.001);
}

test "Anim.in_out : symétrique, mid = 0.5" {
    var a = Anim.init(0, 0, 1, 100);
    a.ease = .in_out;
    try expectApprox(a.progress(50), 0.5, 0.001);
    try expect(a.progress(10) < 0.5 and a.progress(90) > 0.5);
}

test "Scroll : layout décale les enfants, content/viewport calculés, clamp" {
    var s: Scroll = .{};
    var items: [4]Node = undefined;
    var ptrs: [4]*Node = undefined;
    for (&items, &ptrs, 0..) |*it, *p, i| {
        it.* = .{ .size = .{ .px = 100 } };
        _ = i;
        p.* = it;
    }
    var root: Node = .{ .axis = .column, .scroll = &s, .children = &ptrs };
    s.offset = 150;
    layout(&root, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try expectApprox(s.viewport, 200, 0.001);
    try expectApprox(s.content, 400, 0.001); // 4×100, pas de gap
    try expectApprox(items[0].bounds.y, -150, 0.001); // décalé
    try expectApprox(items[3].bounds.y, 150, 0.001); // 300-150
    try expectApprox(s.maxOffset(), 200, 0.001);
    // clamp : on ne peut pas scroller au-delà
    try expect(!s.setOffset(150)); // déjà à 150 → pas de changement
    try expect(s.setOffset(9999));
    try expectApprox(s.offset, 200, 0.001); // clampé au maxOffset
    try expect(!s.scrollBy(50)); // déjà au fond
    try expect(s.scrollBy(-100));
    try expectApprox(s.offset, 100, 0.001);
}

test "Scroll.ensureVisible : défile le minimum, inset IME, plus grand que le viewport" {
    var s: Scroll = .{ .content = 1000, .viewport = 100 };
    // déjà visible → pas de mouvement
    try expect(!s.ensureVisible(10, 30, 0));
    // en dessous du pli → scroll juste assez (r_max au bas de la zone visible)
    try expect(s.ensureVisible(200, 220, 0));
    try expectApprox(s.offset, 120, 0.001);
    // au-dessus → remonte jusqu'à r_min en haut
    try expect(s.ensureVisible(50, 70, 0));
    try expectApprox(s.offset, 50, 0.001);
    // inset IME 60px : la zone visible effective = viewport−60 = 40
    s.offset = 0;
    try expect(s.ensureVisible(50, 70, 60)); // 70 > 0+40 → offset = 30
    try expectApprox(s.offset, 30, 0.001);
    try expect(!s.ensureVisible(50, 70, 60)); // 50..70 ∈ [30,70] → visible
    // élément plus grand que la zone visible → aligner le haut
    s.offset = 0;
    try expect(s.ensureVisible(200, 300, 0));
    try expectApprox(s.offset, 200, 0.001);
    // inset qui mange tout le viewport → no-op
    try expect(!s.ensureVisible(400, 420, 200));
}

test "dispatchScrollable : wheel atteint le scroll, drag suit le doigt" {
    var s: Scroll = .{ .fixed_content = true, .content = 1000 };
    var item: Node = .{ .size = .{ .px = 50 }, .on_pointer = countHit };
    var ptrs: [1]*Node = .{&item};
    var root: Node = .{ .axis = .column, .scroll = &s, .children = &ptrs };
    layout(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    // wheel sur l'item → le scroll parent le consomme
    try expect(dispatchScrollable(&root, .{ .kind = .wheel, .x = 10, .y = 10, .dy = 40 }) == &root);
    try expectApprox(s.offset, 40, 0.001);
    // drag : down claim, move scrolle, up termine
    try expect(dispatchScrollable(&root, .{ .kind = .down, .x = 10, .y = 50 }) == &root);
    try expect(dispatchScrollable(&root, .{ .kind = .move, .x = 10, .y = 30 }) == &root);
    try expectApprox(s.offset, 60, 0.001); // tiré vers le haut → +20
    try expect(dispatchScrollable(&root, .{ .kind = .up, .x = 10, .y = 30 }) == &root);
    try expect(s.drag == null);
    // hors bounds → rien
    try expect(dispatchScrollable(&root, .{ .kind = .wheel, .x = 500, .y = 10, .dy = 10 }) == null);
}

var built: usize = 0;
fn buildTile(slot: *Node, index: usize, ctx: ?*anyopaque) void {
    _ = index;
    _ = ctx;
    built += 1;
    slot.semantics = .{ .role = .list_item, .label = "item" };
}

test "LazyList : fenêtre virtuelle — seuls les items visibles sont matérialisés" {
    built = 0;
    var slots: [8]Node = undefined;
    var ptrs: [9]*Node = undefined; // slots.len + 1 (index 0 = spacer)
    var ll: LazyList = .{
        .count = 10000,
        .item_extent = 50,
        .builder = buildTile,
        .slots = &slots,
        .slot_ptrs = &ptrs,
    };
    ll.initNode();
    try expectApprox(ll.scroll.content, 500000, 0.001); // 10000×50
    // viewport 200 → items 0..4 visibles (offset 0)
    ll.host_node.bounds = .{ .x = 0, .y = 0, .w = 300, .h = 200 };
    try expect(ll.syncWindow());
    try expect(ll.first == 0 and ll.view_count == 4);
    try expect(built == 4); // 10000 items, 4 construits
    // scroll à l'item 10 → fenêtre 10..14
    _ = ll.scroll.setOffset(500);
    try expect(ll.syncWindow());
    try expect(ll.first == 10 and ll.view_count == 4);
    try expect(built == 8);
    // offset qui révèle un nouvel item partiel → rebuild
    _ = ll.scroll.setOffset(510);
    try expect(ll.syncWindow()); // item 14 entre en vue → 5 slots
    try expect(ll.view_count == 5 and built == 13); // 4+4+5 : slots recyclés
    // même fenêtre, scroll interne → pas de rebuild
    _ = ll.scroll.setOffset(505);
    try expect(!ll.syncWindow());
    try expect(built == 13);
    // layout place les slots aux positions décalées (offset=505)
    ll.relayout();
    try expectApprox(slots[0].bounds.y, -5, 0.001); // item10 : 500 - 505
    try expectApprox(slots[3].bounds.y, 145, 0.001); // item13 : 650 - 505
    // slot0 (item10) occupe -5..45 → visible partiellement
    try expect(slots[0].bounds.contains(10, 10));
}

test "collectSemantics : DFS plat, rôles/parents/labels" {
    var t1: Node = .{ .semantics = .{ .role = .text, .label = "Titre" } };
    const btn: Node = .{ .semantics = .{ .role = .button, .label = "Lire", .focusable = true } };
    var wrap: Node = .{}; // pas de rôle → transparent
    var row: Node = .{ .axis = .row, .children = &.{ &t1, &wrap } };
    var wrapped_btn: Node = btn;
    var inner: [1]*Node = .{&wrapped_btn};
    wrap.children = &inner;
    var root: Node = .{ .axis = .column, .children = &.{&row} };
    layout(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    var list: std.ArrayList(SemItem) = .empty;
    defer list.deinit(std.testing.allocator);
    try collectSemantics(&root, std.testing.allocator, &list, null);
    try expect(list.items.len == 2);
    try expect(list.items[0].role == .text);
    try expect(list.items[1].role == .button);
    // le bouton sous wrap hérite du parent DFS → le text (ancêtre le plus proche)
    try expect(list.items[1].parent == null); // root n'est pas sémantique → null
    try expect(list.items[1].focusable);
    try expect(std.mem.eql(u8, list.items[0].label, "Titre"));
}

test "TextField : insert, caret utf8, sélection, delete" {
    var f: TextField = .{};
    f.insert("hello");
    try expect(f.len == 5 and f.caret == 5);
    f.insert(" wörld"); // ö = 2 octets
    try expect(f.len == 12);
    // move -1 depuis la fin passe la frontière utf8
    f.moveCaret(-1, false);
    try expect(f.caret == 11); // devant 'd'
    f.moveCaret(-1, false);
    try expect(f.caret == 10); // devant 'l'
    f.moveCaret(-1, false);
    try expect(f.caret == 9); // devant 'r'
    f.moveCaret(-1, false); // recule devant "ö" (2 octets) d'un coup
    try expect(f.caret == 7);
    // sélection "wörld" (5 chars = 6 octets) puis remplace
    f.home(false);
    f.end(true);
    try expect(f.hasSelection());
    f.insert("bye");
    try expect(std.mem.eql(u8, f.text(), "bye"));
    f.deleteBackward();
    try expect(std.mem.eql(u8, f.text(), "by"));
    f.home(false);
    f.deleteForward();
    try expect(std.mem.eql(u8, f.text(), "y"));
}

test "TextField : composition IME remplace puis commit" {
    var f: TextField = .{};
    f.insert("test");
    f.setCaret(4, false);
    f.compose("か"); // pré-edit
    try expect(f.comp_len == 3); // か = 3 octets
    try expect(std.mem.eql(u8, f.text(), "testか"));
    f.compose("かな"); // composition s'étend
    try expect(std.mem.eql(u8, f.text(), "testかな"));
    f.commit(""); // commit final
    try expect(f.comp_len == 0);
    try expect(std.mem.eql(u8, f.text(), "test"));
    try expect(f.caret == f.len);
}

test "Focus : cycle DFS wrap, set/unset du flag focused" {
    var a: Node = .{ .semantics = .{ .role = .button, .focusable = true } };
    var b: Node = .{ .semantics = .{ .role = .text_field, .focusable = true } };
    var c: Node = .{ .semantics = .{ .role = .slider, .focusable = true } };
    var mid: Node = .{ .axis = .row, .children = &.{ &b, &c } };
    var root: Node = .{ .axis = .column, .children = &.{ &a, &mid } };

    var f: Focus = .{};
    try expect(f.move(&root, 1, std.testing.allocator) == &a);
    try expect(a.focused);
    try expect(f.move(&root, 1, std.testing.allocator) == &b); // descend dans mid
    try expect(!a.focused and b.focused);
    try expect(f.move(&root, 1, std.testing.allocator) == &c);
    try expect(f.move(&root, 1, std.testing.allocator) == &a); // wrap
    try expect(f.move(&root, -1, std.testing.allocator) == &c); // wrap arrière
    try expect(f.move(&root, -1, std.testing.allocator) == &b);
    f.set(null);
    try expect(!b.focused);
    // sans focus courant : dir<0 → dernier
    try expect(f.move(&root, -1, std.testing.allocator) == &c);
}

// ---------------------------------------------------------------------------
// Thème — tokens couleur (v1 : valeurs directes, pas de resolution dynamique).
// L'app lit `ui.theme` au boot et fabrique ses paints depuis les tokens.
// Convention Flutter/Material : bg/surface/text/accent ; `light` fourni pour
// vérifier le contraste sur les deux palettes.
// ---------------------------------------------------------------------------
pub const Theme = struct {
    bg: u32 = 0x12121AFF,        // fond app
    surface: u32 = 0x1E1E2EFF,   // cartes/champs
    surface2: u32 = 0x26263AFF,  // élévations, tuiles actives
    border: u32 = 0x2A2A38FF,    // strokes/dividers
    text: u32 = 0xE8E6F0FF,
    text_muted: u32 = 0x9C9CB8FF,
    accent: u32 = 0x6C5CE7FF,    // violet primaire
    accent2: u32 = 0x00CEC9FF,   // cyan secondaire
    selection: u32 = 0x6C5CE744, // surlignage texte (alpha)
    focus: u32 = 0x00CEC9FF,     // anneau de focus clavier
    danger: u32 = 0xE74C3CFF,

    // Géométrie + typo (tokens — widgets les consomment à la place des
    // littéraux quand ils sont posés).
    r_sm: f32 = 6,
    r_md: f32 = 10,
    r_lg: f32 = 16,
    gap: f32 = 8,
    pad: f32 = 12,
    text_sm: f32 = 13,
    text_md: f32 = 15,
    text_lg: f32 = 20,

    pub const dark: Theme = .{};
    pub const light: Theme = .{
        .bg = 0xF5F5FAFF,
        .surface = 0xFFFFFFFF,
        .surface2 = 0xEAEAF2FF,
        .border = 0xD8D8E4FF,
        .text = 0x1A1A26FF,
        .text_muted = 0x5A5A72FF,
        .accent = 0x5B4BD6FF,
        .accent2 = 0x009B96FF,
        .selection = 0x5B4BD633,
        .focus = 0x009B96FF,
        .danger = 0xD63C2EFF,
    };

    /// Dynamic color — palette dérivée d'une couleur "seed" (0xRRGGBBAA),
    /// façon Material You. Conversion sRGB→OKLab→LCh : les tons (L) pilotent
    /// bg/surface/texte, la teinte (h) teinte les neutres et l'accent.
    /// Version SIMPLIFIÉE OKLab — pas le pipeline HCT/CAM16 de Google
    /// (résultats proches visuellement, contraste non garanti AAA).
    pub fn fromSeed(seed: u32, dark_mode: bool) Theme {
        const srgb = lchOf(seed);
        // Accent : préserve la teinte, remonte C pour la lisibilité.
        const ac_l = if (dark_mode) @max(srgb.l, 0.62) else @min(srgb.l, 0.55);
        const ac_c = @min(@max(srgb.c * 1.15, 0.09), 0.16);
        const accent = rgb(ac_l, ac_c, srgb.h);
        // Secondaire : teinte pivotée 120° (triadique).
        const accent2 = rgb(if (dark_mode) 0.68 else 0.50, 0.12, srgb.h + 120);
        const nc = @min(srgb.c * 0.18, 0.025); // neutre teinté, très désaturé
        const th: Theme = if (dark_mode)
            .{
                .bg = rgb(0.13, nc, srgb.h),
                .surface = rgb(0.19, nc * 1.2, srgb.h),
                .surface2 = rgb(0.25, nc * 1.4, srgb.h),
                .border = rgb(0.30, nc, srgb.h),
                .text = rgb(0.93, nc * 0.8, srgb.h),
                .text_muted = rgb(0.68, nc, srgb.h),
                .accent = accent,
                .accent2 = accent2,
                .selection = accent & 0xFFFFFF00 | 0x55,
                .focus = accent2,
                .danger = rgb(0.68, 0.17, 30),
            }
        else
            .{
                .bg = rgb(0.95, nc, srgb.h),
                .surface = rgb(0.99, nc, srgb.h),
                .surface2 = rgb(0.91, nc * 1.3, srgb.h),
                .border = rgb(0.83, nc, srgb.h),
                .text = rgb(0.16, nc * 0.8, srgb.h),
                .text_muted = rgb(0.44, nc, srgb.h),
                .accent = accent,
                .accent2 = accent2,
                .selection = accent & 0xFFFFFF00 | 0x44,
                .focus = accent2,
                .danger = rgb(0.58, 0.17, 30),
            };
        return th;
    }
};

// ---- OKLab (Björn Ottosson) — conversions linéarisées ---------------------
const Lch = struct { l: f32, c: f32, h: f32 };

fn srgbLin(u: u8) f32 {
    const c: f32 = @as(f32, @floatFromInt(u)) / 255;
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}
fn srgbUnlin(c: f32) u8 {
    const s = if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    return @intFromFloat(std.math.clamp(s * 255, @as(f32, 0), @as(f32, 255)));
}
fn lchOf(rgba: u32) Lch {
    const r = srgbLin(@intCast(rgba >> 24 & 0xFF));
    const g = srgbLin(@intCast(rgba >> 16 & 0xFF));
    const b = srgbLin(@intCast(rgba >> 8 & 0xFF));
    const l = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    const a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    const bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    return .{ .l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
              .c = @sqrt(a * a + bb * bb),
              .h = std.math.atan2(bb, a) * 180 / std.math.pi };
}
fn rgb(l: f32, c: f32, h_deg: f32) u32 {
    const h = h_deg * std.math.pi / 180;
    const a = c * @cos(h);
    const b = c * @sin(h);
    const ll = l + 0.3963377774 * a + 0.2158037573 * b;
    const mm = l - 0.1055613458 * a - 0.0638541728 * b;
    const ss = l - 0.0894841775 * a - 1.2914855480 * b;
    const l3 = ll * ll * ll;
    const m3 = mm * mm * mm;
    const s3 = ss * ss * ss;
    const r = srgbUnlin(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3);
    const g = srgbUnlin(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3);
    const bb = srgbUnlin(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3);
    return @as(u32, r) << 24 | @as(u32, g) << 16 | @as(u32, bb) << 8 | 0xFF;
}

/// Thème actif — l'app le remplace au boot (ui.theme = .light) avant de
/// construire ses paints. Mutabilité globale assumée : thème = données
/// de session, pas hot-swap frame-par-frame.
pub var theme: Theme = .dark;

// ---------------------------------------------------------------------------
// Spring — oscillateur amorti (stiffness/damping, convention Flutter).
// Utilisation : poser `to(target)`, pomper `step(dt_s)` tant que `!done()`.
// Intégration Euler semi-implicite à pas fixe 1/240s — stable jusqu'à
// stiffness ~1200 ; au-delà clamp explicite (on préfère un spring mou
// à une explosion numérique).
// ---------------------------------------------------------------------------
pub const Spring = struct {
    x: f32 = 0,   // position courante
    v: f32 = 0,   // vitesse courante
    t: f32 = 0,   // cible
    stiffness: f32 = 300, // k (unité/s²)
    damping: f32 = 30,    // c — 2√k = critique ; < = rebond, > = mou
    mass: f32 = 1,

    /// damping_ratio = c / (2·√(k·m)) : <1 rebond, =1 critique, >1 mou.
    pub fn dampingRatio(s: *const Spring) f32 {
        return s.damping / (2 * @sqrt(s.stiffness * s.mass));
    }

    pub fn set(s: *Spring, x: f32) void {
        s.x = x;
        s.t = x;
        s.v = 0;
    }
    pub fn to(s: *Spring, target: f32) void {
        s.t = target;
    }
    /// Avance la simulation de dt_s ; renvoie false si arrivé au repos
    /// (snap sur la cible sous ε — l'app arrête de marquer dirty).
    pub fn step(s: *Spring, dt_s: f32) bool {
        if (s.done()) return false;
        var rem = @min(dt_s, 0.1); // évite le bond géant après lag
        const h: f32 = 1.0 / 240.0;
        while (rem > 0) {
            const dt = @min(rem, h);
            const k = @min(s.stiffness, 1200); // garde-fou stabilité
            const a = (-k * (s.x - s.t) - s.damping * s.v) / s.mass;
            s.v += a * dt;
            s.x += s.v * dt;
            rem -= dt;
        }
        if (@abs(s.x - s.t) < 0.0005 and @abs(s.v) < 0.005) {
            s.x = s.t;
            s.v = 0;
            return false;
        }
        return true;
    }
    pub fn done(s: *const Spring) bool {
        return @abs(s.x - s.t) < 0.0005 and @abs(s.v) < 0.005;
    }
};

test "Spring : converge sur la cible, sans dépassement en critique" {
    var s: Spring = .{ .stiffness = 300, .damping = 2 * @sqrt(@as(f32, 300)) };
    s.set(0);
    s.to(1);
    var i: usize = 0;
    var overshoot = false;
    while (s.step(1.0 / 60.0) and i < 600) : (i += 1) {
        if (s.x > 1.001) overshoot = true;
    }
    try expect(i < 600); // a convergé
    try expect(s.x == 1 and s.v == 0);
    try expect(!overshoot); // critique : jamais au-delà de la cible
}

test "Theme.fromSeed : teinte seed préservée, dark/light cohérents" {
    const red = Theme.fromSeed(0xE74C3CFF, true);
    // L'accent dérivé d'un seed rouge reste dans les rouges (teinte ±15°).
    const h_accent = lchOf(red.accent).h;
    const h_seed = lchOf(0xE74C3CFF).h;
    var dh = @abs(h_accent - h_seed);
    if (dh > 180) dh = 360 - dh;
    try std.testing.expect(dh < 15);
    // Dark : bg sombre + texte clair ; Light : inverse.
    const light = Theme.fromSeed(0xE74C3CFF, false);
    try std.testing.expect(lchOf(red.bg).l < 0.25);
    try std.testing.expect(lchOf(red.text).l > 0.85);
    try std.testing.expect(lchOf(light.bg).l > 0.85);
    try std.testing.expect(lchOf(light.text).l < 0.25);
    // Roundtrip OKLab : une couleur convertie revient ~identique (±2/255).
    const back = lchOf(0x6C5CE7FF);
    const rt = rgb(back.l, back.c, back.h);
    try std.testing.expect(@abs(@as(i32, @intCast(rt >> 24 & 0xFF)) - 0x6C) <= 2);
}

test "Spring : sous-amorti rebondit puis se stabilise" {
    var s: Spring = .{ .stiffness = 300, .damping = 8 };
    s.set(0);
    s.to(1);
    var max_x: f32 = 0;
    var i: usize = 0;
    while (s.step(1.0 / 60.0) and i < 1200) : (i += 1) {
        max_x = @max(max_x, s.x);
    }
    try expect(max_x > 1.05); // a bien rebondi
    try expect(i < 1200);     // puis convergé quand même
}
