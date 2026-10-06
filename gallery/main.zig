// gallery/main.zig — app démo K2 : LazyList virtualisée (10k items),
// widgets (Button/Toggle/Slider/TextField), sémantique, host SDL3 dirty-loop.
// Mesure : compte les matérialisations (preuve virtualization) + stats host.
const std = @import("std");
const builtin = @import("builtin");
const k = @import("klaxon");
const is_wasm = k.is_wasm;
const is_ios = builtin.os.tag == .ios;
const is_android = builtin.abi == .android;
const is_windows = builtin.os.tag == .windows;
extern fn emscripten_get_now() f64; // ms — lazy : jamais émis hors wasm
const kx = k.kx;
const ui = k.ui;
const sdl = k.sdl;
const w = k.widgets;

// Fenêtre slots : couvre ~2300px à item_extent 36px min. Le compteur
// `slots_saturated` du JSON signale un viewport non couvert (bug remonté
// par l'agent Android : 16 slots = moitié basse vide sur 2400px).
const SLOTS = 64;
const TILE_PX = 56;

const TileCtx = struct { g: *G, index: usize, slot: *ui.Node };

const G = struct {
    host: k.Host = undefined,
    // peintures
    p_bg: *kx.Paint = undefined,
    p_card: *kx.Paint = undefined,
    p_sel_anim: *kx.Paint = undefined,
    p_card_alt: *kx.Paint = undefined,
    p_sel_tile: *kx.Paint = undefined,
    p_toolbar: *kx.Paint = undefined,
    p_accent: *kx.Paint = undefined,
    p_accent_press: *kx.Paint = undefined,
    p_track: *kx.Paint = undefined,
    p_knob: *kx.Paint = undefined,
    p_field: *kx.Paint = undefined,
    p_field_stroke: *kx.Paint = undefined,
    p_caret: *kx.Paint = undefined,
    p_sel: *kx.Paint = undefined,
    p_comp: *kx.Paint = undefined,
    p_div: *kx.Paint = undefined,
    // paras
    title_para: *kx.Para = undefined,
    btn_para: *kx.Para = undefined,
    tog_para: *kx.Para = undefined,
    field_para: *kx.Para = undefined,
    prefix_para: *kx.Para = undefined,
    // widgets
    btn: w.Button = .{},
    tog: w.Toggle = .{},
    sli: w.Slider = .{},
    fld: w.TextFieldView = .{},
    // arbre
    root: ui.Node = .{},
    header: ui.Node = .{},
    toolbar: ui.Node = .{},
    divider_node: ui.Node = .{},
    // disc custom (exercice kx_draw v2 : path/ombre/gradients/dash)
    disc_node: ui.Node = .{},
    disc_path: *kx.Path = undefined,
    p_disc_card: *kx.Paint = undefined,
    p_ring: *kx.Paint = undefined,
    p_wave: *kx.Paint = undefined,
    p_glass_fill: *kx.Paint = undefined,
    p_glass_stroke: *kx.Paint = undefined,
    glass_para: *kx.Para = undefined,
    glass_para2: *kx.Para = undefined,
    // lazy list
    list: ui.LazyList = undefined,
    slots: [SLOTS]ui.Node = undefined,
    ptrs: [SLOTS + 1]*ui.Node = undefined,
    slot_para: [SLOTS]?*kx.Para = @splat(null), // lazy : créés à la matérialisation

    slot_kids: [SLOTS][2]ui.Node = undefined,
    slot_kid_ptrs: [SLOTS][2]*ui.Node = undefined,
    slot_label: [SLOTS][96]u8 = undefined,
    tile_ctx: [SLOTS]TileCtx = undefined,
    selected: ?usize = null,
    selected_slot: ?*ui.Node = null,
    sel_anim: ?ui.Anim = null, // highlight sélection : dirty tant que vivante
    extent_spring: ui.Spring = .{}, // hauteur de tuile animée au slider
    last_ms: i64 = 0,
    focus: ui.Focus = .{},
    p_focus: *kx.Paint = undefined,
    striped: bool = true,
    sem_dirty: bool = true, // arbre sémantique à re-pousser (ponts a11y natifs)
    materializations: usize = 0,
    max_slots_used: usize = 0,
    frames: i64 = 0,
    fonts_dir: ?[]const u8 = null,
    max_frames: i64 = -1,
    running: bool = true,
    io: std.Io = undefined,
    dirty_extra: bool = true,
    deadline_ms: i64 = -1, // --secs : sortie auto pour CI
    boot_t0_us: i96 = -1,  // marque entrée runGallery → ttff host
    inject: ?[]const u8 = null, // --inject : texte injecté via SDL_PushEvent
    a11y_at: i64 = -1,          // --a11y : dump programmatique + activate test à t=ms
    a11y_dumped: bool = false,
    key_inject: ?u32 = null,    // --key <code> [mod] : key_down injecté (Tab etc.)
    wheel_left: i64 = 0,        // --wheel N : N wheel events espacés (scroll réel)
    wheel_at: i64 = 0,
    gpu_arg: []const u8 = "",   // --gpu dawn|vulkan|gl (Windows ; défaut dawn)
    inject_at: i64 = -1,
    inject_buf: [256]u8 = undefined,
    ime_shift: f32 = 0,          // Android #13166 : lift du layout au-dessus de l'IME
    ime_watch_until: i64 = -1,   // fenêtre d'échantillonnage insets post-focus
    ime_bottom_last: i32 = -1,
    ime_visible_last: i32 = -1,
    a11y_pending_node: ?*ui.Node = null, // Android : cb JNI → thread SDL
    a11y_pending_action: c_int = 0,
    bottombar: ui.Node = .{},           // vérif #13166 : --bottom-field
    bottom_field: bool = false,          // place fld en bas (champ couvert par l'IME)
};

var g: G = .{};

fn nowMs() i64 {
    if (is_wasm) return @intFromFloat(emscripten_get_now());
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(g.io, .awake).raw.nanoseconds, 1_000_000));
}

/// mix(a, b, t) : blend linéaire canal par canal (t=0 → a, 1 → b).
fn mix(a: u32, b: u32, t: f32) u32 {
    const tt = @min(1, @max(0, t));
    const ac = [4]u8{ @intCast(a & 0xFF), @intCast((a >> 8) & 0xFF), @intCast((a >> 16) & 0xFF), @intCast((a >> 24) & 0xFF) };
    const bc = [4]u8{ @intCast(b & 0xFF), @intCast((b >> 8) & 0xFF), @intCast((b >> 16) & 0xFF), @intCast((b >> 24) & 0xFF) };
    var r: u32 = 0;
    for (0..4) |i| {
        const v: u8 = @intFromFloat(@as(f32, @floatFromInt(ac[i])) * (1 - tt) + @as(f32, @floatFromInt(bc[i])) * tt);
        r |= @as(u32, v) << @intCast(i * 8);
    }
    return r;
}

fn isDark(c: u32) bool {
    return (@as(u32, c & 0xFF) + ((c >> 8) & 0xFF) + ((c >> 16) & 0xFF)) < 0x180;
}

fn mkPaint(rgba: u32) *kx.Paint {
    const p = kx.kx_paint_new().?;
    kx.kx_paint_color(p, rgba);
    return p;
}

fn mkPara(g_: *G) *kx.Para {
    return kx.kx_para_new(g_.host.ctx, g_.host.fonts).?;
}

fn paraOf(p: *kx.Para, size: f32, rgba: u32, text: []const u8, wpx: f32) void {
    _ = kx.kx_para_reset(p);
    _ = kx.kx_para_push_style(p, size, rgba, 400, 0);
    _ = kx.kx_para_add_text_n(p, text.ptr, text.len);
    _ = kx.kx_para_max_lines(p, 1);
    _ = kx.kx_para_layout(p, wpx);
}

// Font stack : "Famille1, Famille2" → indices ordonnés (CSS-like) ; les
// noms absents sont ignorés, index 0 toujours ajouté en dernier recours.
fn paraOfFamilies(p: *kx.Para, size: f32, rgba: u32, text: []const u8,
                  wpx: f32, families: []const u8) void {
    var idx_buf: [16]c_int = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, families, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0 or n >= idx_buf.len) continue;
        var nb: [128]u8 = undefined;
        @memcpy(nb[0..name.len], name);
        nb[name.len] = 0;
        const idx = kx.kx_fonts_family_index(g.host.fonts, @ptrCast(&nb));
        if (idx >= 0) { idx_buf[n] = idx; n += 1; }
    }
    idx_buf[n] = 0; n += 1; // dernier recours
    _ = kx.kx_para_reset(p);
    _ = kx.kx_para_push_style_families(p, size, rgba, 400, &idx_buf, @intCast(n));
    _ = kx.kx_para_add_text_n(p, text.ptr, text.len);
    _ = kx.kx_para_max_lines(p, 1);
    _ = kx.kx_para_layout(p, wpx);
}

// ---------------------------------------------------------------------------
// LazyList builder — ne matérialise que les items de la fenêtre visible.
// ---------------------------------------------------------------------------
fn buildTile(slot: *ui.Node, index: usize, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    const si = (@intFromPtr(slot) - @intFromPtr(&gg.slots[0])) / @sizeOf(ui.Node);
    gg.materializations += 1;
    const lbl = std.fmt.bufPrint(&gg.slot_label[si], "Piste #{d} — album Demo · 3:{d:0>2}", .{ index, index % 60 }) catch "?";
    // para retenu par slot (créé une fois)
    if (gg.slot_para[si] == null) gg.slot_para[si] = mkPara(gg);
    paraOf(gg.slot_para[si].?, 16, ui.theme.text, lbl, 2000);
    // rangée : [spacer 16][texte]
    gg.slot_kids[si][0] = .{ .size = .{ .px = 16 } };
    gg.slot_kids[si][1] = .{ .paint = .{ .text = gg.slot_para[si] }, .semantics = .{ .role = .text, .label = lbl } };
    gg.slot_kid_ptrs[si][0] = &gg.slot_kids[si][0];
    gg.slot_kid_ptrs[si][1] = &gg.slot_kids[si][1];
    slot.axis = .row;
    slot.gap = 0;
    slot.children = &gg.slot_kid_ptrs[si];
    // état visuel + interaction
    if (gg.selected == index) {
        slot.paint.fill = gg.p_sel_tile;
        slot.selected = true;
        gg.selected_slot = slot;
    } else {
        slot.paint.fill = if (gg.striped and index % 2 == 1) gg.p_card_alt else gg.p_card;
        slot.selected = false;
        if (gg.selected_slot == slot) gg.selected_slot = null; // slot recyclé
    }
    gg.tile_ctx[si] = .{ .g = gg, .index = index, .slot = slot };
    slot.userdata = &gg.tile_ctx[si];
    slot.on_pointer = tileTap;
    slot.semantics = .{ .role = .list_item, .label = lbl };
    gg.sem_dirty = true; // labels matérialisés changent → re-sync a11y
}

fn tileTap(n: *ui.Node, ev: ui.PointerEvent) void {
    const tc: *TileCtx = @ptrCast(@alignCast(n.userdata orelse return));
    if (ev.kind != .up) return;
    const gg = tc.g;
    if (gg.selected_slot) |s| { s.paint.fill = gg.p_card; s.selected = false; }
    n.paint.fill = gg.p_sel_tile;
    n.selected = true;
    gg.selected_slot = n;
    gg.selected = tc.index;
    gg.sel_anim = ui.Anim.init(nowMs() * 1000, 0, 1, 220_000); // 220 ms
    gg.sem_dirty = true; // A11Y_SELECTED change
    gg.dirty_extra = true;
}

// ---------------------------------------------------------------------------
// Callbacks widgets
// ---------------------------------------------------------------------------
fn onAdd100(ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    gg.list.count += 100;
    gg.list.initNode(); // re-calcule scroll.content
    gg.dirty_extra = true;
}

fn onToggle(on: bool, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    gg.striped = on;
    gg.list.invalidate();
    gg.dirty_extra = true;
}

fn onSlider(v: f32, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    // cible du spring : la tuile suit la valeur avec un rebond amorti
    gg.extent_spring.to(32 + v * 64);
    gg.dirty_extra = true;
}

fn onFieldFocus(focused: bool, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    if (focused) {
        _ = sdl.SDL_StartTextInput(gg.host.win);
        // bounds en pixels ; SDL attend des coords fenêtre (points) → /scale
        // (Retina @2/@3 : sans ça la zone IME dérive d'un facteur scale).
        const b = gg.fld.node.bounds;
        const s: f32 = @floatCast(@max(1.0, gg.host.scale));
        const r = sdl.SDL_Rect{ .x = @intFromFloat(b.x / s), .y = @intFromFloat(b.y / s), .w = @intFromFloat(b.w / s), .h = @intFromFloat(b.h / s) };
        _ = sdl.SDL_SetTextInputArea(gg.host.win, &r, 0);
    } else {
        _ = sdl.SDL_StopTextInput(gg.host.win);
    }
}

// ---------------------------------------------------------------------------
// Rafraîchit les paras/mesures du champ quand field.dirty.
// caret_x = largeur du préfixe texte[0..caret] (para auxiliaire).
// ---------------------------------------------------------------------------
fn refreshField() void {
    const f = &g.fld;
    const s = f.field.text();
    paraOf(g.field_para, 15, if (s.len > 0) ui.theme.text else ui.theme.text_muted, if (s.len > 0) s else "Rechercher…", 2000);
    f.para = g.field_para;
    // mesures préfixe : caret / sélection / composition
    const lo = @min(f.field.caret, f.field.anchor);
    const hi = @max(f.field.caret, f.field.anchor);
    paraOf(g.prefix_para, 15, ui.theme.text, s[0..f.field.caret], 2000);
    f.caret_x = kx.kx_para_max_intrinsic_width(g.prefix_para);
    paraOf(g.prefix_para, 15, ui.theme.text, s[0..lo], 2000);
    f.sel_lo_x = kx.kx_para_max_intrinsic_width(g.prefix_para);
    paraOf(g.prefix_para, 15, ui.theme.text, s[0..hi], 2000);
    f.sel_hi_x = kx.kx_para_max_intrinsic_width(g.prefix_para);
    paraOf(g.prefix_para, 15, ui.theme.text, s[0..@min(f.field.comp_start, s.len)], 2000);
    f.comp_lo_x = kx.kx_para_max_intrinsic_width(g.prefix_para);
    paraOf(g.prefix_para, 15, ui.theme.text, s[0..@min(f.field.comp_start + f.field.comp_len, s.len)], 2000);
    f.comp_hi_x = kx.kx_para_max_intrinsic_width(g.prefix_para);
    f.field.dirty = false;
    g.dirty_extra = true;
}

// ---------------------------------------------------------------------------
// Routing événements host → ui
// ---------------------------------------------------------------------------
/// Focus manager → sync du modèle TextField (caret + SDL text input).
fn focusSet(n: ?*ui.Node) void {
    g.focus.set(n);
    g.sem_dirty = true; // flags focused changent
    const has_f = g.focus.current == &g.fld.node;
    if (g.fld.field.focused != has_f) {
        g.fld.field.focused = has_f;
        onFieldFocus(has_f, &g);
    }
}

/// Activation AT (action 0=press) : rejoue un tap au centre du node exposé.
fn a11yPress(ctx: ?*anyopaque, node: *ui.Node, action: c_int) void {
    _ = ctx;
    if (comptime is_android) {
        // cb JNI sur thread UI → marshal vers le thread SDL (tick draine).
        g.a11y_pending_node = node;
        g.a11y_pending_action = action;
        return;
    }
    a11yPressRun(node, action);
}

fn a11yPressRun(node: *ui.Node, action: c_int) void {
    if (action == 1 or action == 2) {
        // increment/decrement (slider RangeValue / adjustable) : rejoue la
        // vraie touche flèche sur le node focusé — right=+, left=-.
        focusSet(node);
        const key: u32 = if (action == 1) sdl.SDLK_RIGHT else sdl.SDLK_LEFT;
        onEvent(.{ .key_down = .{ .key = key, .mod = 0 } });
        return;
    }
    if (action != 0) return; // actions inconnues ignorées
    const cx = node.bounds.x + node.bounds.w / 2;
    const cy = node.bounds.y + node.bounds.h / 2;
    onEvent(.{ .pointer_down = .{ .x = cx, .y = cy, .button = 1 } });
    onEvent(.{ .pointer_up = .{ .x = cx, .y = cy, .button = 1 } });
}

fn onEvent(e: k.Event) void {
    switch (e) {
        .pointer_down => |p| {
            const ev = ui.PointerEvent{ .kind = .down, .x = p.x, .y = p.y, .button = p.button };
            _ = ui.dispatchScrollable(&g.root, ev);
            const hit = ui.dispatch(&g.root, ev);
            // clic → focus sur le hit focusable (ou blur si hors widget)
            if (hit) |h| {
                focusSet(if (h.semantics.focusable) h else null);
            } else focusSet(null);
            g.dirty_extra = true;
        },
        .pointer_up => |p| {
            const ev = ui.PointerEvent{ .kind = .up, .x = p.x, .y = p.y, .button = p.button };
            _ = ui.dispatchScrollable(&g.root, ev);
            _ = ui.dispatch(&g.root, ev);
            g.dirty_extra = true;
        },
        .pointer_move => |p| {
            const ev = ui.PointerEvent{ .kind = .move, .x = p.x, .y = p.y };
            _ = ui.dispatchScrollable(&g.root, ev);
            _ = ui.dispatch(&g.root, ev);
            g.dirty_extra = true;
        },
        .wheel => |p| {
            // dy SDL positif = scroll vers le haut → offset diminue.
            const ev = ui.PointerEvent{ .kind = .wheel, .x = p.x, .y = p.y, .dy = -p.dy * TILE_PX };
            _ = ui.dispatchScrollable(&g.root, ev);
            g.dirty_extra = true;
        },
        .text_input => |t| {
            if (g.fld.field.focused) {
                if (g.fld.field.comp_len > 0) g.fld.field.commit(t) else g.fld.field.insert(t);
            }
        },
        .text_editing => |t| {
            if (g.fld.field.focused) g.fld.field.compose(t.text);
        },
        .key_down => |ke| {
            if (ke.key == sdl.SDLK_TAB) {
                // cycle DFS des focusables ; shift+tab recule
                var fba_buf: [8 * 1024]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
                const dir: i32 = if ((ke.mod & sdl.KMOD_SHIFT) != 0) -1 else 1;
                _ = g.focus.move(&g.root, dir, fba.allocator());
                focusSet(g.focus.current); // sync le modèle TextField
            } else if (g.focus.current) |c| {
                if (c.on_key) |f| _ = f(c, ke.key, ke.mod);
            }
            g.dirty_extra = true;
        },
        .resized => g.dirty_extra = true,
        else => {},
    }
}

fn lerpChannel(a: u32, b: u32, t: f32) u32 {
    const av: f32 = @floatFromInt(a);
    return @intFromFloat(av + (@as(f32, @floatFromInt(b)) - av) * t);
}

fn lerpColor(ca: u32, cb: u32, t: f32) u32 {
    // RGBA packed u32 — lerp par canal (A incluse).
    return (lerpChannel((ca >> 24) & 0xFF, (cb >> 24) & 0xFF, t) << 24) |
        (lerpChannel((ca >> 16) & 0xFF, (cb >> 16) & 0xFF, t) << 16) |
        (lerpChannel((ca >> 8) & 0xFF, (cb >> 8) & 0xFF, t) << 8) |
        lerpChannel(ca & 0xFF, cb & 0xFF, t);
}

fn draw(h: *k.Host) void {
    const t = h.target;
    _ = kx.kx_canvas_clear(t, ui.theme.bg); // fond
    // re-layout à chaque frame (v1 — le dirty gate amortit déjà)
    var pw: c_int = 0;
    var ph: c_int = 0;
    kx.kx_target_size(t, &pw, &ph);
    // Android #13166 : aucun event SDL à l'ouverture du clavier (PAN décale
    // le contenu sans signal — mesuré en K2-prep). On échantillonne
    // WindowInsets.ime() en JNI tant qu'un champ est focusé et on soulève
    // tout le layout de `ime_shift` px (le hit-test reste cohérent : les
    // bounds sont celles du layout décalé).
    if (comptime is_android) {
        const ns = computeImeShift();
        if (ns != g.ime_shift) { // bounds mutées → re-pousser l'arbre a11y
            g.ime_shift = ns;
            g.sem_dirty = true;
        }
        if (g.fld.field.focused and g.ime_watch_until < 0)
            g.ime_watch_until = nowMs() + 2500;
        sampleIme();
    }
    ui.layout(&g.root, .{ .x = 0, .y = -g.ime_shift, .w = @floatFromInt(pw), .h = @floatFromInt(ph) });
    _ = g.list.syncWindow();
    if (g.list.view_count > g.max_slots_used) g.max_slots_used = g.list.view_count;
    g.list.relayout();
    // Anim sélection : échantillonne par frame, dirty tant que vivante —
    // le host continue de dessiner sans événement utilisateur.
    if (g.sel_anim) |a| {
        const now_us = nowMs() * 1000;
        const v = a.value(now_us);
        kx.kx_paint_color(g.p_sel_anim, lerpColor(ui.theme.surface, mix(ui.theme.accent, ui.theme.text, 0.25), v));
        if (g.selected_slot) |s| s.paint.fill = g.p_sel_anim;
        if (a.done(now_us)) g.sel_anim = null else h.dirty = true;
    }
    g.root.draw(t);
    // Glass card : panneau flottant par-dessus la liste — backdrop blur du
    // contenu déjà rendu + fill translucide + bordure. Exerce
    // kx_canvas_save_layer_backdrop (K3 verre dépoli).
    // iOS : gx=20 pour recouvrir le texte des items — le blur devient
    // visible ; ph-210 poserait la carte SOUS le viewport borné de la liste
    // (rien derrière → flou invisible) sur l'aspect 402×874 portrait.
    const gx: f32 = if (comptime is_ios) 20 else @as(f32, @floatFromInt(@divTrunc(pw, 2) - 160));
    const gy: f32 = if (comptime is_ios) @as(f32, @floatFromInt(@divTrunc(ph, 3))) else @as(f32, @floatFromInt(ph)) - 210;
    // fBackdrop filtre dans le CLIP (pas fBounds — hint d'alloc seulement) :
    // clipper aux bounds arrondies avant le layer sinon le flou fuit partout.
    _ = kx.kx_canvas_save(t);
    _ = kx.kx_canvas_clip_rrect(t, gx, gy, 340, 150, 16, 16);
    if (kx.kx_canvas_save_layer_backdrop(t, gx, gy, 340, 150, 14) == 0) {
        _ = kx.kx_canvas_draw_rrect(t, gx, gy, 340, 150, 16, 16, g.p_glass_fill);
        _ = kx.kx_canvas_draw_rrect(t, gx, gy, 340, 150, 16, 16, g.p_glass_stroke);
        _ = kx.kx_para_draw(g.glass_para, t, gx + 18, gy + 18);
        _ = kx.kx_para_draw(g.glass_para2, t, gx + 18, gy + 58);
        _ = kx.kx_canvas_restore(t);
    }
    _ = kx.kx_canvas_restore(t);
    h.presentTarget();
}

// iOS : le Mach-O entre par main → SDL_RunApp → UIApplicationMain →
// SDLUIKitDelegate.postFinishLaunch appelle forward sur le main thread
// (modèle officiel SDL3-iOS : pump événementiel manuel via PollEvent).
// g_init vit tant que main est bloqué dans UIApplicationMain (jamais
// retourné) — le forward le consomme en sécurité.
var g_init: std.process.Init = undefined;

extern fn SDL_RunApp(argc: c_int, argv: [*c][*c]u8, main_func: *const fn (c_int, [*c][*c]u8) callconv(.c) c_int, reserved: ?*anyopaque) c_int;

// ---- Android : sondes WindowInsets JNI (vérité #13166) --------------------
extern fn kx_ime_bottom() c_int;
extern fn kx_ime_visible() c_int;
extern fn kx_view_bottom() c_int;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fwrite(ptr: [*]const u8, size: usize, n: usize, f: ?*anyopaque) usize;
extern fn fclose(f: ?*anyopaque) c_int;

/// Lift nécessaire pour garder le champ focusé au-dessus du clavier.
/// bounds.y inclut déjà le shift courant (layout.y = -shift) → on réajoute
/// pour retrouver la position naturelle, puis need = bottom_naturel −
/// (view_h − ime_bottom).
fn computeImeShift() f32 {
    if (!g.fld.field.focused) return 0;
    const b = kx_ime_bottom();
    if (b <= 0) return 0;
    // bounds = coords écran post-shift : on réajoute le shift courant pour
    // retrouver la position naturelle (stabilité — sinon oscillation 0↔873
    // mesurée par l'agent Android).
    const field_bottom = g.fld.node.bounds.y + g.fld.node.bounds.h + g.ime_shift;
    const view_h = @as(f32, @floatFromInt(kx_view_bottom()));
    return @max(0, field_bottom - (view_h - @as(f32, @floatFromInt(b))));
}

/// Trace l'évolution IME dans la fenêtre de veille (debug insets).
fn sampleIme() void {
    if (g.ime_watch_until < 0) return;
    const b = kx_ime_bottom();
    const v = kx_ime_visible();
    if (b != g.ime_bottom_last or v != g.ime_visible_last) {
        g.ime_bottom_last = b;
        g.ime_visible_last = v;
        std.debug.print("[ime] bottom={} visible={} shift={d:.0}\n", .{ b, v, g.ime_shift });
    }
    if (nowMs() > g.ime_watch_until) g.ime_watch_until = -1;
}

fn sdlIosForward(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    runGallery(g_init) catch |e| {
        std.debug.print("[gallery] runGallery error: {s}\n", .{@errorName(e)});
        if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t);
        return 1;
    };
    return 0;
}

pub fn main(init: std.process.Init) !void {
    if (comptime is_ios) {
        g_init = init;
        const v = init.minimal.args.vector;
        const rc = SDL_RunApp(@intCast(v.len), @ptrCast(@constCast(v.ptr)), sdlIosForward, null);
        if (rc != 0) return error.RunAppFailed;
        return;
    }
    return runGallery(init);
}

// ---- Entrée Android : SDLActivity → SDL_main → kx_gallery_main -------------
// (main() est inatteignable sous SDL_main-Android : l'activité appelle
// SDL_main dans le glue JNI, qui forward ici). Synthétise un
// std.process.Init comme start.zig (arena + c_allocator + Io.Threaded +
// environ vide — l'app n'a pas besoin de l'env).
export fn kx_gallery_main(argc: c_int, argv: ?[*:null]?[*:0]u8) c_int {
    if (comptime !is_android) return -1;
    var argv_buf: [64][*:0]const u8 = undefined;
    const n: usize = @min(@as(usize, @intCast(@max(0, argc))), 64);
    const av = argv orelse return -1;
    for (0..n) |i| argv_buf[i] = av[i] orelse "gallery";
    const args: []const [*:0]const u8 = argv_buf[0..n];
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const gpa = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args }),
        .environ = .empty,
    });
    var environ_map = std.process.Environ.createMap(.empty, gpa) catch return -2;
    const init: std.process.Init = .{
        .minimal = .{ .args = .{ .vector = args }, .environ = .empty },
        .arena = &arena_state,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    };
    runGallery(init) catch |e| {
        std.debug.print("kx_gallery_main error: {s}\n", .{@errorName(e)});
        return -3;
    };
    return 0;
}

fn runGallery(init: std.process.Init) !void {
    if (is_wasm) return; // web : main appelé au load — JS pilote gallery_init/step
    g.io = init.io;
    g.boot_t0_us = k.host.nowUs(init.io); // ttff : notre code démarre ici
    // args : --frames N (sortie automatique pour le bench/CI)
    // initAllocator requis sur Windows (WTF-8) ; Iterator.init y est
    // un compileError. (diff retourné par l'agent K3-Windows)
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            if (args.next()) |n| g.max_frames = std.fmt.parseInt(i64, n, 10) catch -1;
        }
        if (std.mem.eql(u8, a, "--secs")) {
            if (args.next()) |n| {
                const s = std.fmt.parseInt(i64, n, 10) catch 0;
                g.deadline_ms = nowMs() + s * 1000;
            }
        }
        if (std.mem.eql(u8, a, "--theme")) {
            if (args.next()) |tn| {
                if (std.mem.eql(u8, tn, "light")) {
                    ui.theme = .light;
                } else if (std.mem.eql(u8, tn, "auto")) {
                    // GNOME/desktop : hint système (SDL_GetSystemTheme) —
                    // natif seulement ; wasm/unknown → dark par défaut.
                    if (!is_wasm) {
                        if (sdl.SDL_GetSystemTheme() == .light) ui.theme = .light;
                    }
                }
            }
        } else if (std.mem.eql(u8, a, "--seed")) {
            // Dynamic color : palette OKLab dérivée du seed (dark par défaut,
            // --theme light avant --seed pour la variante claire).
            if (args.next()) |sv| {
                const seed = std.fmt.parseInt(u32, sv, 0) catch 0x6C5CE7FF;
                ui.theme = ui.Theme.fromSeed(seed, isDark(ui.theme.bg));
            }
        } else if (std.mem.eql(u8, a, "--fonts")) {
            if (args.next()) |dir| g.fonts_dir = dir; // appliqué après setup()
        } else if (std.mem.eql(u8, a, "--wheel")) {
            if (args.next()) |wn| {
                g.wheel_left = std.fmt.parseInt(i64, wn, 10) catch 0;
                g.wheel_at = nowMs() + 800;
            }
        } else if (std.mem.eql(u8, a, "--key")) {
            if (args.next()) |kc| {
                g.key_inject = std.fmt.parseInt(u32, kc, 0) catch null;
                g.inject_at = nowMs() + 600;
            }
        } else if (std.mem.eql(u8, a, "--gpu")) {
            // Windows : dawn (d3d12, primaire) | vulkan | gl (fallback).
            if (args.next()) |gm| g.gpu_arg = gm;
        } else if (std.mem.eql(u8, a, "--inject")) {
            if (args.next()) |txt| {
                g.inject = txt; // vit jusqu'à la fin du process (args)
                g.inject_at = nowMs() + 800;
            }
        } else if (std.mem.eql(u8, a, "--bottom-field")) {
            // Vérif #13166 : le champ toolbar n'est jamais couvert par l'IME —
            // ce flag le déplace dans une barre en bas pour exercer ime_shift.
            g.bottom_field = true;
        } else if (std.mem.eql(u8, a, "--a11y")) {
            // dump vérif : éléments + traits + frames écran + activate bouton
            g.a11y_at = nowMs() + 1500;
        } else if (std.mem.eql(u8, a, "--a11y-at")) {
            // idem mais à t=ms (ex: après un scroll manuel → mutation)
            if (args.next()) |n| g.a11y_at = nowMs() + (std.fmt.parseInt(i64, n, 10) catch 1500);
        }
    }

    // fonte : disque en natif Linux, embarquée ailleurs (pas de chemin
    // /usr/share/fonts hors Linux ; --fonts <dir> reste dispo pour la stack).
    const font_data = if (is_wasm or builtin.os.tag == .windows or is_ios or builtin.os.tag == .macos or is_android)
        @embedFile("DejaVuSans.ttf")
    else
        try std.Io.Dir.cwd().readFileAlloc(g.io, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", init.gpa, .limited(8 << 20));
    defer if (!is_wasm and builtin.os.tag != .windows and !is_ios and builtin.os.tag != .macos and !is_android) init.gpa.free(font_data); // Skia copie le blob
    try setup(font_data);
    g.host.markBoot(g.boot_t0_us);

    while (g.running) tick();

    // stats JSON (honnêteté : driver réel consigné). Android : stderr n'est
    // pas capturé par logcat → écrit aussi dans files/k4-gallery.json.
    var sbuf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&sbuf,
        "{{\"tool\":\"k2-gallery\",\"backend\":\"{s}\",\"driver\":\"{s}\",\"frames\":{},\"avg_frame_ms\":{d:.3},\"p99_frame_ms\":{d:.3},\"pacing_p99_ms\":{d:.3},\"first_frame_ms\":{d:.3},\"ttff_ms\":{d:.3},\"resizes\":{},\"idle_iters\":{},\"minimized_iters\":{},\"materializations\":{},\"max_slots_used\":{},\"items\":{},\"slots_saturated\":{},\"ime_shift_px\":{d:.1},\"ime_bottom\":{},\"ime_visible\":{},\"peak_rss_mb\":{d:.1}}}\n",
        .{
            @tagName(g.host.backend()), g.host.driverInfo(), g.host.stats.frames,
            g.host.stats.avgFrameMs(), g.host.stats.p99FrameMs(), g.host.stats.p99IntervalMs(),
            g.host.stats.first_frame_ms, g.host.stats.ttff_ms, g.host.stats.resizes,
            g.host.stats.idle_iters, g.host.stats.minimized_iters,
            g.materializations, g.max_slots_used, g.list.count, g.list.saturated,
            g.ime_shift, g.ime_bottom_last, g.ime_visible_last,
            @as(f64, @floatFromInt(k.Stats.peakRssKb())) / 1024.0,
        },
    ) catch "";
    std.debug.print("{s}", .{line});
    if (comptime is_android) {
        if (fopen("/data/data/org.libsdl.app/files/k4-gallery.json", "w")) |f| {
            _ = fwrite(line.ptr, 1, line.len, f);
            _ = fclose(f);
        }
    }
    g.host.deinit();
}

/// Tout le setup partagé natif/wasm : host, fonte, peintures, widgets, arbre.
fn setup(font_data: []const u8) !void {
    g.host = if (is_wasm)
        try k.Host.initCanvasWindow("Klaxon Gallery", 900, 700)
    else if (comptime builtin.os.tag == .windows) blk: {
        // Windows : dawn-d3d12 primaire (défaut), vulkan secondaire, gl fallback.
        const gm = if (g.gpu_arg.len == 0) "dawn" else g.gpu_arg;
        if (std.mem.eql(u8, gm, "dawn"))
            break :blk try k.Host.initDawnWindow(g.io, "Klaxon Gallery", 900, 700, .d3d12);
        if (std.mem.eql(u8, gm, "vulkan"))
            break :blk try k.Host.initDawnWindow(g.io, "Klaxon Gallery", 900, 700, .vulkan);
        break :blk try k.Host.initGlWindow(g.io, "Klaxon Gallery", 900, 700);
    } else if (comptime is_ios)
        // iOS : graphite-metal via SDL_Metal_CreateView (même chemin que mac).
        // SDL ignore la taille demandée — la fenêtre = écran plein UIKit.
        try k.Host.initMetalWindow(g.io, "Klaxon Gallery", 402, 874)
    else if (comptime builtin.os.tag == .macos)
        // macOS : graphite-metal onscreen via SDL_Metal_CreateView→CAMetalLayer
        // (chemin prouvé K1-mac ; pas de GL accéléré dispo partout).
        try k.Host.initMetalWindow(g.io, "Klaxon Gallery", 900, 700)
    else
        try k.Host.initGlWindow(g.io, "Klaxon Gallery", 900, 700);
    _ = kx.kx_fonts_add(g.host.fonts, font_data.ptr, font_data.len);
    if (g.fonts_dir) |dir| {
        var zb: [4096]u8 = undefined;
        @memcpy(zb[0..dir.len], dir);
        zb[dir.len] = 0;
        const n = kx.kx_fonts_add_dir(g.host.fonts, @ptrCast(&zb));
        std.debug.print("fonts: {} fichier(s) depuis {s}\n", .{ n, dir });
    }

    // peintures (0xRRGGBBAA)
    const th = ui.theme;
    g.p_card = mkPaint(th.surface);
    g.p_card_alt = mkPaint(th.bg);
    g.p_sel_tile = mkPaint(mix(th.accent, th.text, 0.25));
    g.p_sel_anim = mkPaint(mix(th.accent, th.text, 0.25));
    g.p_toolbar = mkPaint(th.surface);
    g.p_accent = mkPaint(th.accent);
    g.p_accent_press = mkPaint(mix(th.accent, 0x000000FF, 0.15));
    g.p_track = mkPaint(th.border);
    g.p_knob = mkPaint(th.text);
    g.p_field = mkPaint(th.bg);
    g.p_field_stroke = mkPaint(th.border);
    kx.kx_paint_style(g.p_field_stroke, 1); // stroke
    kx.kx_paint_stroke_width(g.p_field_stroke, 1);
    g.p_caret = mkPaint(th.accent2);
    g.p_sel = mkPaint(th.selection);
    g.p_comp = mkPaint(th.accent2);
    g.p_div = mkPaint(th.border);
    g.p_focus = mkPaint(th.focus);
    kx.kx_paint_style(g.p_focus, 1); // stroke
    kx.kx_paint_stroke_width(g.p_focus, 2);
    g.p_bg = mkPaint(th.bg);

    // --- disc custom (kx_draw v2) — gradients en espace local du node : la
    // custom draw translate le canvas sur bounds.x/y avant de dessiner.
    g.p_disc_card = mkPaint(0xFFFFFFFF);
    kx.kx_paint_gradient_radial(g.p_disc_card, 22, 22, 20, &.{ 0x3A3A55FF, 0x1E1E2EFF }, null, 2);
    g.p_ring = mkPaint(0xFFFFFFFF);
    kx.kx_paint_style(g.p_ring, 1);
    kx.kx_paint_stroke_width(g.p_ring, 3.5);
    kx.kx_paint_stroke_cap(g.p_ring, 1);
    kx.kx_paint_gradient_sweep(g.p_ring, 22, 22, -90, 270, &.{ 0x6C5CE7FF, 0x00CEC9FF, 0x6C5CE7FF }, null, 3);
    g.p_wave = mkPaint(0x8CE8E6FF);
    // glass : fill translucide + bordure lumineuse (le flou vient du backdrop)
    g.p_glass_fill = mkPaint(mix(th.surface, 0x00000000, 0.32));
    g.p_glass_stroke = mkPaint(mix(th.text, 0x00000000, 0.25));
    kx.kx_paint_style(g.p_glass_stroke, 1);
    kx.kx_paint_stroke_width(g.p_glass_stroke, 1.5);
    kx.kx_paint_style(g.p_wave, 1);
    kx.kx_paint_stroke_width(g.p_wave, 1.8);
    kx.kx_paint_stroke_cap(g.p_wave, 1);
    kx.kx_paint_stroke_join(g.p_wave, 1);
    kx.kx_paint_dash(g.p_wave, 2.5, 2.0);
    g.disc_path = kx.kx_path_new().?;
    g.disc_node = .{
        .size = .{ .px = 44 },
        .cross = 44,
        .paint = .{ .custom = discDraw },
        .userdata = &g,
        .semantics = .{ .role = .image, .label = "Disc — lecture en cours" },
    };

    // paras
    g.title_para = mkPara(&g);
    paraOfFamilies(g.title_para, 20, ui.theme.text,
        "Klaxon Gallery — \xE4\xB8\xAD\xE6\x96\x87 \xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4 ñ ελληνικά Привет", 2000,
        "DejaVu Sans, Noto Sans SC");
    g.btn_para = mkPara(&g);
    paraOf(g.btn_para, 14, if (isDark(ui.theme.accent)) @as(u32, 0xFFFFFFFF) else ui.theme.text, "+100 pistes", 2000);
    g.tog_para = mkPara(&g);
    paraOf(g.tog_para, 13, ui.theme.text_muted, "alterné", 2000);
    g.field_para = mkPara(&g);
    g.prefix_para = mkPara(&g);

    // lazy list : items uniformes 56px, 10 000 pistes
    g.list = .{
        .count = 10000,
        .item_extent = TILE_PX,
        .builder = buildTile,
        .ctx = &g,
        .slots = &g.slots,
        .slot_ptrs = &g.ptrs,
    };
    g.list.initNode();
    g.list.host_node.semantics = .{ .role = .list, .label = "Bibliothèque" };
    _ = g.list.syncWindow();

    // widgets
    g.btn = .{ .on_tap = onAdd100, .ctx = &g, .normal = g.p_accent, .active = g.p_accent_press };
    g.btn.node.size = .{ .px = 110 };
    g.btn.node.cross = 36;
    g.btn.node.paint.text = g.btn_para;
    g.btn.node.paint.text_align = .center;
    g.btn.node.semantics.label = "Ajouter 100 pistes";
    g.btn.node.paint.focus_ring = g.p_focus;
    g.btn.bind();

    g.tog = .{ .on = true, .on_change = onToggle, .ctx = &g, .off_paint = g.p_track, .on_paint = g.p_accent };
    g.tog.node.size = .{ .px = 56 };
    g.tog.node.cross = 28;
    g.tog.node.semantics.label = "Lignes alternées";
    g.tog.node.paint.focus_ring = g.p_focus;
    g.tog.bind();

    g.sli = .{ .value = 0.375, .on_change = onSlider, .ctx = &g, .track = g.p_track, .fill = g.p_accent, .knob = g.p_knob };
    g.sli.node.size = .{ .px = 160 };
    g.sli.node.cross = 36;
    g.sli.node.semantics.label = "Hauteur des pistes";
    g.sli.node.paint.focus_ring = g.p_focus;
    g.sli.bind();

    g.fld = .{
        .on_focus = onFieldFocus,
        .ctx = &g,
        .caret_paint = g.p_caret,
        .sel_paint = g.p_sel,
        .comp_paint = g.p_comp,
    };
    g.fld.node.size = .{ .weight = 1 };
    g.fld.node.cross = 40;
    g.fld.node.paint.fill = g.p_field;
    g.fld.node.paint.stroke = g.p_field_stroke;
    g.fld.node.semantics.label = "Champ de recherche";
    g.fld.node.paint.focus_ring = g.p_focus;
    g.fld.bind();
    g.fld.field.focused = false;

    // arbre : header + toolbar + divider + liste
    g.header = .{ .size = .{ .px = 60 }, .pad = 16, .paint = .{ .text = g.title_para }, .semantics = .{ .role = .header, .label = "Klaxon Gallery" } };
    g.toolbar = .{ .size = .{ .px = 56 }, .axis = .row, .pad = 10, .gap = 12, .paint = .{ .fill = g.p_toolbar }, .children = &.{ &g.disc_node, &g.btn.node, &g.tog.node, &g.sli.node, &g.fld.node } };
    g.glass_para = mkPara(&g);
    paraOf(g.glass_para, 18, ui.theme.text, "Glass — backdrop blur σ14", 400);
    g.glass_para2 = mkPara(&g);
    g.host.setA11yActionHandler(a11yPress, &g); // AT → tap dispatch
    paraOf(g.glass_para2, 13, ui.theme.text_muted, "La liste dessous est floutée par le layer", 400);
    g.divider_node = w.divider(g.p_div);
    if (g.bottom_field) {
        g.toolbar.children = &.{ &g.disc_node, &g.btn.node, &g.tog.node, &g.sli.node };
        g.bottombar = .{ .size = .{ .px = 56 }, .axis = .row, .pad = 10, .gap = 12, .paint = .{ .fill = g.p_toolbar }, .children = &.{ &g.fld.node } };
        g.root = .{ .axis = .column, .children = &.{ &g.header, &g.toolbar, &g.divider_node, &g.list.host_node, &g.bottombar } };
    } else {
        g.root = .{ .axis = .column, .children = &.{ &g.header, &g.toolbar, &g.divider_node, &g.list.host_node } };
    }

    g.extent_spring.set(56); // 0.375×64+32 : valeur initiale du slider
    g.extent_spring.stiffness = 180;
    g.extent_spring.damping = 14; // sous-critique : rebond visible ~1.2
    g.last_ms = nowMs();
    std.debug.print("gallery: backend={s} driver={s}\n", .{ @tagName(g.host.backend()), g.host.driverInfo() });
}

/// Custom draw du widget disc — exerce kx_draw v2 : path rrect + ombre
/// portée, arc stroke à gradient sweep (espace local via translate), et
/// polyligne zigzag en dash. Le clip sur bounds est posé par Node.draw.
fn discDraw(t: ?*kx.Target, b: ui.Rect, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    _ = kx.kx_canvas_save(t);
    _ = kx.kx_canvas_translate(t, b.x, b.y);
    kx.kx_path_reset(gg.disc_path);
    kx.kx_path_add_rrect(gg.disc_path, 2, 3, b.w - 4, b.h - 6, 10, 10);
    _ = kx.kx_canvas_draw_shadow(t, gg.disc_path, 6, 600, 0x00000044, 0x00000077, 0);
    _ = kx.kx_canvas_draw_path(t, gg.disc_path, gg.p_disc_card);
    const cx = b.w / 2;
    const cy = b.h / 2;
    const r: f32 = 13;
    kx.kx_path_reset(gg.disc_path);
    kx.kx_path_arc_to(gg.disc_path, cx - r, cy - r, r * 2, r * 2, -90, 300, 1);
    _ = kx.kx_canvas_draw_path(t, gg.disc_path, gg.p_ring);
    kx.kx_path_reset(gg.disc_path);
    kx.kx_path_move_to(gg.disc_path, cx - 9, cy);
    kx.kx_path_line_to(gg.disc_path, cx - 5, cy - 5);
    kx.kx_path_line_to(gg.disc_path, cx - 1, cy + 5);
    kx.kx_path_line_to(gg.disc_path, cx + 3, cy - 7);
    kx.kx_path_line_to(gg.disc_path, cx + 7, cy + 3);
    kx.kx_path_line_to(gg.disc_path, cx + 9, cy);
    _ = kx.kx_canvas_draw_path(t, gg.disc_path, gg.p_wave);
    _ = kx.kx_canvas_restore(t);
}

/// Une itération de la boucle (partagée natif `while` / wasm `gallery_step`).
fn tick() void {
    if (g.deadline_ms > 0 and nowMs() >= g.deadline_ms) {
        g.running = false;
        return;
    }
    if (g.inject != null and nowMs() >= g.inject_at) {
        // injection SDL_PushEvent : vérifie toute la chaîne
        // TEXT_INPUT→insert→redraw moins le lien X11→SDL (mort sur cette VM)
        g.fld.field.focused = true;
        onFieldFocus(true, &g);
        const txt = g.inject.?;
        const n = @min(txt.len, g.inject_buf.len - 1);
        @memcpy(g.inject_buf[0..n], txt[0..n]);
        g.inject_buf[n] = 0;
        var ev: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .reserved = 0, .timestamp = 0, .windowID = sdl.SDL_GetWindowID(g.host.win), .text = @ptrCast(&g.inject_buf) } };
        _ = sdl.SDL_PushEvent(&ev);
        g.inject = null;
    }
    if (g.wheel_left > 0 and nowMs() >= g.wheel_at) {
        // molette réelle dans le viewport liste → scroll→materialization
        var ev: sdl.SDL_Event = .{ .wheel = .{
            .type = sdl.SDL_EVENT_MOUSE_WHEEL, .reserved = 0, .timestamp = 0,
            .windowID = sdl.SDL_GetWindowID(g.host.win), .which = 0,
            .x = 0, .y = -1, .direction = 0, .mouse_x = 300, .mouse_y = 500,
            .integer_x = 0, .integer_y = -1,
        } };
        _ = sdl.SDL_PushEvent(&ev);
        g.wheel_left -= 1;
        g.wheel_at = nowMs() + 40;
    }
    if (g.key_inject != null and nowMs() >= g.inject_at) {
        var ev: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .reserved = 0, .timestamp = 0, .windowID = sdl.SDL_GetWindowID(g.host.win), .which = 0, .scancode = 0, .key = g.key_inject.?, .mod = 0, .raw = 0, .down = true, .repeat = false } };
        _ = sdl.SDL_PushEvent(&ev);
        g.key_inject = null;
    }
    if (!g.host.pollEvents(onEvent)) {
        g.running = false;
        return;
    }
    if (g.fld.field.dirty) refreshField();
    if (g.dirty_extra) {
        g.host.dirty = true;
        g.dirty_extra = false;
    }
    // spring item_extent : la tuile glisse vers la cible du slider
    const now = nowMs();
    const dt_s: f32 = @floatFromInt(@max(1, now - g.last_ms));
    g.last_ms = now;
    if (g.extent_spring.step(dt_s / 1000)) {
        g.list.item_extent = g.extent_spring.x;
        g.list.initNode();
        g.list.invalidate();
        g.host.dirty = true;
    }
    // Android : draine une action a11y marshallée depuis le thread UI.
    if (comptime is_android) {
        // #13166 : l'ouverture IME n'émet aucun event SDL — pomper des frames
        // tant que la veille post-focus est ouverte pour échantillonner
        // WindowInsets.ime() et appliquer ime_shift.
        if (g.ime_watch_until > 0) g.host.dirty = true;
        if (g.a11y_pending_node) |n| {
            g.a11y_pending_node = null;
            a11yPressRun(n, g.a11y_pending_action);
        }
    }
    // Ponts a11y natifs : re-push quand l'arbre a muté (le shim déduplique).
    // Web = le JS pollue gallery_semantics_sync séparément, rien à faire ici.
    if (g.sem_dirty) {
        g.sem_dirty = false;
        var fba = std.heap.FixedBufferAllocator.init(&sem_arena_buf);
        g.host.syncA11y(&g.root, fba.allocator()) catch {};
    }
    // --a11y : dump programmatique de l'arbre posé + activate test, puis
    // re-dump toutes les 6s (vérif mutation). iOS only (symbole shim).
    if (comptime is_ios) {
        if (!g.a11y_dumped and g.a11y_at > 0 and nowMs() >= g.a11y_at) {
            g.a11y_dumped = true;
            if (g.host.view) |v| kx.kx_a11y_debug_dump(@ptrCast(v));
            g.a11y_at = nowMs() + 6000;
            g.a11y_dumped = false;
        }
    }
    // --frames N = mode bench : force le dessin tant que le budget n'est pas
    // atteint — sinon la dirty-gate gèle au repos et N ne se termine jamais
    // (piège remonté par l'agent Windows : --frames ne sort jamais seul).
    if (g.max_frames > 0 and g.frames < g.max_frames) g.host.dirty = true;
    // wait 4ms idle en natif (throttle WaitEventTimeout), 0 en wasm (rAF pace)
    switch (g.host.step(draw, null, if (is_wasm) 0 else 4)) {
        .drew => {
            g.frames += 1;
            if (g.max_frames > 0 and g.frames >= g.max_frames) g.running = false;
        },
        .quit => g.running = false,
        .idle => {},
    }
}

// --- Entrées wasm : JS pilote init + une itération par rAF -----------------
export fn gallery_init() c_int {
    const font: []const u8 = @embedFile("DejaVuSans.ttf");
    setup(font) catch return -1;
    return 0;
}

export fn gallery_step() c_int {
    tick();
    return @intCast(g.frames);
}

/// Tap synthétique par le chemin RÉEL de dispatch (down+up) — utilisé par
/// le pont a11y web : un clic lecteur d'écran sur le DOM ARIA appelle
/// gallery_tap au centre du node, qui passe par dispatch/scrollable/focus
/// comme un vrai pointeur.
export fn gallery_tap(x: c_int, y: c_int) c_int {
    if (!is_wasm) return -1;
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    onEvent(.{ .pointer_down = .{ .x = fx, .y = fy, .button = 1 } });
    onEvent(.{ .pointer_up = .{ .x = fx, .y = fy, .button = 1 } });
    return 0;
}

export fn gallery_kick() c_int {
    g.dirty_extra = true;
    tick();
    return @intCast(g.frames);
}

// Diagnostics wasm — 0/1 sans allocation.
export fn gallery_target_ok() c_int {
    return if (g.host.target != null) 1 else 0;
}
export fn gallery_backend() c_int {
    return @intFromEnum(g.host.backend());
}

// ---- Pont a11y web : arbre sémantique → JSON pour le DOM ARIA (wasm only) ---
// Le JS reconstruit un DOM positionné invisible calé sur les bounds canvas ;
// les lecteurs d'écran voient alors la même hiérarchie que l'app. Rebuild
// complet par sync (≤ ~40 items matérialisés) — assez cheap pour v1.
var sem_arena_buf: [512 * 1024]u8 = undefined;
var sem_json: [512 * 1024]u8 = undefined;
var sem_json_len: u32 = 0;

fn semRoleName(r: ui.Role) []const u8 {
    return switch (r) {
        .none => "none",
        .text => "text",
        .button => "button",
        .toggle => "checkbox",
        .slider => "slider",
        .text_field => "textbox",
        .list => "list",
        .list_item => "listitem",
        .image => "img",
        .header => "heading",
        .divider => "separator",
    };
}

fn semW(b: *[512 * 1024]u8, o: *usize, s: []const u8) void {
    if (o.* + s.len <= b.len) {
        @memcpy(b[o.*..][0..s.len], s);
        o.* += s.len;
    }
}

export fn gallery_semantics_sync() u32 {
    if (!is_wasm) return 0;
    var fba = std.heap.FixedBufferAllocator.init(&sem_arena_buf);
    const alloc = fba.allocator();
    var items: std.ArrayList(ui.SemItem) = .empty;
    defer items.deinit(alloc);
    ui.collectSemantics(&g.root, alloc, &items, null) catch return 0;
    var wp: usize = 0;
    semW(&sem_json, &wp, "[");
    for (items.items, 0..) |it, i| {
        if (i > 0) semW(&sem_json, &wp, ",");
        var tmp: [192]u8 = undefined;
        const head = std.fmt.bufPrint(&tmp, "{{\"i\":{},\"p\":{},\"r\":\"{s}\",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1},\"f\":{},\"d\":{},\"fo\":{},\"l\":\"", .{
            i,
            if (it.parent) |p| @as(i64, @intCast(p)) else -1,
            semRoleName(it.role),
            it.bounds.x,
            it.bounds.y,
            it.bounds.w,
            it.bounds.h,
            @intFromBool(it.focusable),
            @intFromBool(it.disabled),
            @intFromBool(it.focused),
        }) catch continue;
        semW(&sem_json, &wp, head);
        for (it.label) |c| {
            switch (c) {
                '"' => semW(&sem_json, &wp, "\\\""),
                '\\' => semW(&sem_json, &wp, "\\\\"),
                '\n' => semW(&sem_json, &wp, "\\n"),
                '\r' => semW(&sem_json, &wp, "\\r"),
                '\t' => semW(&sem_json, &wp, "\\t"),
                else => {
                    if (c >= 0x20) {
                        var one: [1]u8 = .{c};
                        semW(&sem_json, &wp, &one);
                    } else {
                        var ub: [8]u8 = undefined;
                        const u = std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch "";
                        semW(&sem_json, &wp, u);
                    }
                },
            }
        }
        semW(&sem_json, &wp, "\"}");
    }
    semW(&sem_json, &wp, "]");
    sem_json_len = @intCast(wp);
    return @intCast(items.items.len);
}

export fn gallery_semantics_ptr() usize {
    return @intFromPtr(&sem_json);
}
export fn gallery_semantics_len() u32 {
    return sem_json_len;
}
