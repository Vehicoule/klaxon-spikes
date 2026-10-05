// widgets.zig — widgets de base K2 sur ui.Node (K2 de la roadmap).
// Modèle : chaque widget = struct d'état + `bind()` qui branche
// node.userdata/on_pointer. L'app déclare `var w = Widget{...}; w.bind();`
// puis insère `&w.node` dans l'arbre — pattern identique à LazyList.
// Aucun nouveau type natif : tout est custom-draw + handler.
const std = @import("std");
const ui = @import("ui.zig");
const kx = @import("kx.zig");
const sdl = @import("sdl.zig");

fn cast(comptime T: type, n: *ui.Node) *T {
    return @ptrCast(@alignCast(n.userdata orelse unreachable));
}

// ---------------------------------------------------------------------------
// Button — carte cliquable (pressed state, tap = up-dans-les-bounds après down)
// ---------------------------------------------------------------------------
pub const Button = struct {
    node: ui.Node = .{},
    on_tap: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    pressed: bool = false,
    enabled: bool = true,
    normal: ?*kx.Paint = null,
    active: ?*kx.Paint = null, // fill quand pressed

    /// À appeler une fois la Button à son adresse finale.
    pub fn bind(b: *Button) void {
        b.node.userdata = b;
        b.node.on_pointer = handle;
        b.node.on_key = keyFn;
        b.node.semantics.role = .button;
        b.node.semantics.focusable = true;
        b.node.semantics.disabled = !b.enabled;
        if (b.normal) |p| b.node.paint.fill = p;
        if (b.node.paint.rx == 0) b.node.paint.rx = 10;
    }

    fn handle(n: *ui.Node, ev: ui.PointerEvent) void {
        const b = cast(Button, n);
        switch (ev.kind) {
            .down => {
                if (!b.enabled) return;
                b.pressed = true;
                if (b.active) |p| n.paint.fill = p;
            },
            .up => {
                const was = b.pressed;
                b.pressed = false;
                if (b.normal) |p| n.paint.fill = p;
                if (was and b.enabled) {
                    if (b.on_tap) |f| f(b.ctx);
                }
            },
            else => {},
        }
    }

    fn keyFn(n: *ui.Node, key: u32, mod: u16) bool {
        _ = mod;
        const b = cast(Button, n);
        switch (key) {
            sdl.SDLK_RETURN, 0x20 => { // Enter / Space
                if (b.enabled) {
                    if (b.on_tap) |f| f(b.ctx);
                }
                return true;
            },
            else => return false,
        }
    }
};

// ---------------------------------------------------------------------------
// Toggle — interrupteur on/off (tap inverse, fill reflète l'état)
// ---------------------------------------------------------------------------
pub const Toggle = struct {
    node: ui.Node = .{},
    on: bool = false,
    on_change: ?*const fn (on: bool, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    off_paint: ?*kx.Paint = null,
    on_paint: ?*kx.Paint = null,

    pub fn bind(t: *Toggle) void {
        t.node.userdata = t;
        t.node.on_pointer = handle;
        t.node.on_key = keyFn;
        t.node.semantics.role = .toggle;
        t.node.semantics.focusable = true;
        t.node.paint.fill = if (t.on) t.on_paint else t.off_paint;
        if (t.node.paint.rx == 0) t.node.paint.rx = 14;
    }

    fn handle(n: *ui.Node, ev: ui.PointerEvent) void {
        const t = cast(Toggle, n);
        if (ev.kind != .up) return;
        t.on = !t.on;
        n.paint.fill = if (t.on) t.on_paint else t.off_paint;
        if (t.on_change) |f| f(t.on, t.ctx);
    }

    fn keyFn(n: *ui.Node, key: u32, mod: u16) bool {
        _ = mod;
        switch (key) {
            sdl.SDLK_RETURN, 0x20 => {
                const t = cast(Toggle, n);
                t.on = !t.on;
                n.paint.fill = if (t.on) t.on_paint else t.off_paint;
                if (t.on_change) |f| f(t.on, t.ctx);
                return true;
            },
            else => return false,
        }
    }
};

// ---------------------------------------------------------------------------
// Slider — valeur 0..1 réglée par down/drag horizontal
// ---------------------------------------------------------------------------
pub const Slider = struct {
    node: ui.Node = .{},
    value: f32 = 0,
    on_change: ?*const fn (value: f32, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    track: ?*kx.Paint = null, // piste inactive
    fill: ?*kx.Paint = null,  // portion remplie
    knob: ?*kx.Paint = null,
    dragging: bool = false,

    pub fn bind(s: *Slider) void {
        s.node.userdata = s;
        s.node.on_pointer = handle;
        s.node.on_key = keyFn;
        s.node.paint.custom = drawFn;
        s.node.semantics.role = .slider;
        s.node.semantics.focusable = true;
    }

    fn setFromX(s: *Slider, n: *const ui.Node, x: f32) void {
        const v = @min(1, @max(0, (x - n.bounds.x) / n.bounds.w));
        if (v != s.value) {
            s.value = v;
            if (s.on_change) |f| f(v, s.ctx);
        }
    }

    fn handle(n: *ui.Node, ev: ui.PointerEvent) void {
        const s = cast(Slider, n);
        switch (ev.kind) {
            .down => {
                s.dragging = true;
                s.setFromX(n, ev.x);
            },
            .move => if (s.dragging) s.setFromX(n, ev.x),
            .up => s.dragging = false,
            .wheel => {},
        }
    }

    /// Dessin : piste centrée 25% de hauteur, remplissage à value, knob.
    fn drawFn(t: ?*kx.Target, b: ui.Rect, ctx: ?*anyopaque) void {
        const s: *Slider = @ptrCast(@alignCast(ctx orelse return));
        const th = b.h * 0.25;
        const cy = b.y + (b.h - th) / 2;
        if (s.track) |p| _ = kx.kx_canvas_draw_rrect(t, b.x, cy, b.w, th, th / 2, th / 2, p);
        const fw = b.w * s.value;
        if (fw > 0) {
            if (s.fill) |p| _ = kx.kx_canvas_draw_rrect(t, b.x, cy, fw, th, th / 2, th / 2, p);
        }
        if (s.knob) |p| _ = kx.kx_canvas_draw_circle(t, b.x + fw, b.y + b.h / 2, @min(b.h, b.h * 0.4), p);
    }

    fn keyFn(n: *ui.Node, key: u32, mod: u16) bool {
        _ = mod;
        const s = cast(Slider, n);
        const step: f32 = 0.05;
        const nv: f32 = switch (key) {
            sdl.SDLK_LEFT => s.value - step,
            sdl.SDLK_RIGHT => s.value + step,
            sdl.SDLK_HOME => 0,
            sdl.SDLK_END => 1,
            else => return false,
        };
        const c = @min(1, @max(0, nv));
        if (c != s.value) {
            s.value = c;
            if (s.on_change) |f| f(c, s.ctx);
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// TextFieldView — liaison ui.TextField (modèle) ↔ node visuel.
// L'app appelle `refresh()` quand field.dirty (rebuild para + caret_x via
// prefix-para : kx_para_max_intrinsic_width(texte[0..caret])).
// ---------------------------------------------------------------------------
pub const TextFieldView = struct {
    node: ui.Node = .{},
    field: ui.TextField = .{},
    /// Para retenu du texte complet (rebuild par l'app dans refresh()).
    para: ?*kx.Para = null,
    /// Position x du caret mesurée côté app (px depuis le début du texte).
    caret_x: f32 = 0,
    /// Bornes x de sélection (px), égales si pas de sélection.
    sel_lo_x: f32 = 0,
    sel_hi_x: f32 = 0,
    caret_paint: ?*kx.Paint = null,
    sel_paint: ?*kx.Paint = null,
    comp_paint: ?*kx.Paint = null, // soulignement pré-edit IME
    comp_lo_x: f32 = 0,
    comp_hi_x: f32 = 0,
    pad: f32 = 12,
    on_focus: ?*const fn (focused: bool, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub fn bind(v: *TextFieldView) void {
        v.node.userdata = v;
        v.node.on_pointer = handle;
        v.node.on_key = keyFn;
        v.node.paint.custom = drawFn;
        v.node.semantics.role = .text_field;
        v.node.semantics.focusable = true;
        if (v.node.paint.rx == 0) v.node.paint.rx = 8;
    }

    fn handle(n: *ui.Node, ev: ui.PointerEvent) void {
        const v = cast(TextFieldView, n);
        if (ev.kind == .down and !v.field.focused) {
            v.field.focused = true;
            if (v.on_focus) |f| f(true, v.ctx);
        }
        // Le mapping clic→caret nécessite les positions glyphes (kx_para) —
        // fourni par l'app via hit-to-caret quand l'ABI l'exposera. v1 :
        // le down place le caret à la fin via app (focus seulement ici).
    }

    fn drawFn(t: ?*kx.Target, b: ui.Rect, ctx: ?*anyopaque) void {
        const v: *TextFieldView = @ptrCast(@alignCast(ctx orelse return));
        const tx = b.x + v.pad;
        var cy = b.y;
        if (v.para) |p| {
            cy = b.y + @max(0, (b.h - kx.kx_para_height(p)) / 2);
            _ = kx.kx_para_draw(p, t, tx, cy);
        }
        if (!v.field.focused) return;
        // Surlignage sélection (sous le texte → dessiné après est faux en
        // v1 : alpha-blend du sel_paint fait le compromis visuel).
        if (v.field.hasSelection()) {
            if (v.sel_paint) |p| {
                _ = kx.kx_canvas_draw_rect(t, tx + v.sel_lo_x, b.y + 6, v.sel_hi_x - v.sel_lo_x, b.h - 12, p);
            }
        }
        // Soulignement de la composition IME.
        if (v.field.comp_len > 0) {
            if (v.comp_paint) |p| {
                _ = kx.kx_canvas_draw_rect(t, tx + v.comp_lo_x, b.y + b.h - 8, v.comp_hi_x - v.comp_lo_x, 2, p);
            }
        }
        // Caret.
        if (v.caret_paint) |p| {
            _ = kx.kx_canvas_draw_rect(t, tx + v.caret_x, b.y + 6, 2, b.h - 12, p);
        }
    }

    fn keyFn(n: *ui.Node, key: u32, mod: u16) bool {
        const v = cast(TextFieldView, n);
        const f = &v.field;
        const ext = (mod & sdl.KMOD_SHIFT) != 0;
        if ((mod & sdl.KMOD_CTRL) != 0) {
            if (key == 'a' or key == 'A') {
                f.selectAll();
                return true;
            }
            return false;
        }
        switch (key) {
            sdl.SDLK_BACKSPACE => f.deleteBackward(),
            sdl.SDLK_DELETE => f.deleteForward(),
            sdl.SDLK_LEFT => f.moveCaret(-1, ext),
            sdl.SDLK_RIGHT => f.moveCaret(1, ext),
            sdl.SDLK_HOME => f.home(ext),
            sdl.SDLK_END => f.end(ext),
            else => return false,
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Helpers nus
// ---------------------------------------------------------------------------
/// Séparateur 1px.
pub fn divider(p: *kx.Paint) ui.Node {
    return .{
        .size = .{ .px = 1 },
        .paint = .{ .fill = p },
        .semantics = .{ .role = .divider },
    };
}

/// Feuille texte (para retenu).
pub fn label(para: *kx.Para, al: ui.TextAlign) ui.Node {
    return .{ .paint = .{ .text = para, .text_align = al } };
}
