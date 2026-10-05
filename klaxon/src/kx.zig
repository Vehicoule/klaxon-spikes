// kx.zig — bindings Zig 0.17 vers l'ABI C kx_skia (handles opaques).
// Source : kx_skia/include/kx_skia.h — garder en sync manuellement
// (passage à `zig translate-c` prévu au moment de la stabilisation ABI).
const std = @import("std");

pub const Ctx = opaque {};
pub const Target = opaque {};
pub const Fonts = opaque {};
pub const Readback = opaque {};

// Backend — valeurs ALIGNÉES sur kx_backend de kx_skia.h (bug trouvé au port
// Windows : l'enum avait dérivé, @tagName/driver affichaient des noms faux).
// ganesh_gl couvre aussi GLES (Android <33) — le driver string distingue.
pub const Backend = enum(c_int) {
    raster = 0,
    ganesh_webgl = 1,
    graphite_webgpu = 2,
    ganesh_gl = 3,
    graphite_vulkan = 4,
    graphite_metal = 5,
    graphite_dawn = 6,
    _,
};

pub const GlGetProc = *const fn ([*c]const u8) callconv(.c) ?*anyopaque;

// contexts — un seul s'applique selon la plateforme cible
pub extern fn kx_ctx_create_raster() ?*Ctx;
pub extern fn kx_ctx_create_ganesh_gl() ?*Ctx;
pub extern fn kx_ctx_create_ganesh_gl_current(get_proc: GlGetProc) ?*Ctx;
pub extern fn kx_ctx_create_ganesh_webgl(canvas_selector: [*c]const u8) ?*Ctx;
pub extern fn kx_ctx_create_graphite_vulkan() ?*Ctx;
pub extern fn kx_ctx_create_graphite_metal() ?*Ctx;
pub extern fn kx_ctx_create_graphite_dawn() ?*Ctx;
pub extern fn kx_ctx_create_graphite_webgpu() ?*Ctx;
pub extern fn kx_ctx_create_graphite_dawn_d3d12() ?*Ctx;
pub extern fn kx_ctx_create_graphite_dawn_vulkan() ?*Ctx;
pub extern fn kx_ctx_backend(ctx: ?*const Ctx) Backend;
pub extern fn kx_ctx_driver_info(ctx: ?*Ctx) [*c]const u8;
pub extern fn kx_ctx_has_unfinished_work(ctx: ?*Ctx) c_int;
pub extern fn kx_ctx_free(ctx: ?*Ctx) void;

// targets
pub extern fn kx_target_onscreen_gl(ctx: ?*Ctx, w: c_int, h: c_int) ?*Target;
pub extern fn kx_target_offscreen(ctx: ?*Ctx, w: c_int, h: c_int) ?*Target;
pub extern fn kx_target_canvas(ctx: ?*Ctx, canvas_selector: [*c]const u8, w: c_int, h: c_int) ?*Target;
/// Cible onscreen Dawn/WebGPU : swapchain attachée au handle natif
/// (HWND Windows, CAMetalLayer macOS, ANativeWindow Android).
pub extern fn kx_target_onscreen_dawn(ctx: ?*Ctx, native_handle: ?*anyopaque, w: c_int, h: c_int) ?*Target;
pub extern fn kx_target_onscreen_metal(ctx: ?*Ctx, ca_metal_layer: ?*anyopaque, w: c_int, h: c_int, scale: f64) ?*Target;

// ---- Accessibilité (impl kx_a11y.mm — Apple seulement ; appels gated
// comptime côté Zig, aucun extern émis ailleurs) ----------------------------
pub const A11yRole = enum(c_int) { generic = 0, button = 1, checkbox = 2, slider = 3, textfield = 4, list = 5, listitem = 6, heading = 7, group = 8 };
pub const A11Y_DISABLED: c_uint = 1;
pub const A11Y_FOCUSABLE: c_uint = 2;
pub const A11Y_FOCUSED: c_uint = 4;
pub const A11Y_SELECTED: c_uint = 8;
pub extern fn kx_a11y_sync_begin(nsview: ?*anyopaque, scale: f64) c_int;
pub extern fn kx_a11y_sync_item(nsview: ?*anyopaque, ident: ?*const anyopaque, parent_ident: ?*const anyopaque, role: c_int, label: ?[*:0]const u8, hint: ?[*:0]const u8, x: f64, y: f64, w: f64, h: f64, flags: c_uint) c_int;
pub extern fn kx_a11y_sync_end(nsview: ?*anyopaque) c_int;
pub extern fn kx_a11y_clear(nsview: ?*anyopaque) void;
pub extern fn kx_a11y_install_hittest(nsview: ?*anyopaque) c_int;
/// cb AT : ident = le node* passé à sync_item (opaque), action 0=press.
pub const A11yActionCb = ?*const fn (ctx: ?*anyopaque, node_ident: ?*anyopaque, action: c_int) callconv(.c) void;
pub extern fn kx_a11y_set_action_handler(view: ?*anyopaque, cb: A11yActionCb, ctx: ?*anyopaque) void;

/// Helpers harnais (hors contrat — bridge interne). debug_dump : énumère
/// programmatiquement l'arbre AX posé (log). activate_ident : appelle le
/// path activate de l'élément `ident`, 1 si appelé.
pub extern fn kx_a11y_debug_dump(view: ?*anyopaque) void;
pub extern fn kx_a11y_activate_ident(view: ?*anyopaque, ident: ?*const anyopaque) c_int;
/// Linux/AT-SPI : draine les requêtes D-Bus en attente (non bloquant).
/// No-op sur les autres plateformes (impl dans kx_a11y_linux.cpp).
pub extern fn kx_a11y_pump() c_int;

/// iOS : 1 quand la UIView SDL est attachée à sa UIWindow (les présents à
/// une vue non attachée sont perdus → écran noir persistant). Autres OS : 1.
pub extern fn kx_ios_window_mapped(uiwindow: ?*anyopaque) c_int;
pub extern fn kx_target_free(t: ?*Target) void;
pub extern fn kx_target_size(t: ?*const Target, w: [*c]c_int, h: [*c]c_int) void;

// fontes
pub extern fn kx_fonts_global() ?*Fonts;
pub extern fn kx_fonts_add(fonts: ?*Fonts, data: ?*const anyopaque, len: usize) c_int;
pub extern fn kx_fonts_add_dir(fonts: ?*Fonts, path: ?[*:0]const u8) c_int;
pub extern fn kx_fonts_family_index(fonts: ?*const Fonts, name: ?[*:0]const u8) c_int;
pub extern fn kx_fonts_count(fonts: ?*const Fonts) c_int;
pub extern fn kx_fonts_free(fonts: ?*Fonts) void;

// rendu corpus (spike) — sera remplacé par l'API Scene/Recording réelle
pub extern fn kx_scene_draw(ctx: ?*Ctx, fonts: ?*Fonts, t: ?*Target, scene: c_int, t_phase: f64) c_int;
pub extern fn kx_present(ctx: ?*Ctx, t: ?*Target) c_int;

// readback (goldens / tests)
pub extern fn kx_readback_start(ctx: ?*Ctx, t: ?*Target) ?*Readback;
pub extern fn kx_readback_poll(ctx: ?*Ctx, rb: ?*Readback) c_int;
pub extern fn kx_readback_copy_n(rb: ?*const Readback, dst: ?*anyopaque, len: usize) i64;
pub extern fn kx_readback_free(rb: ?*Readback) void;

// bench
pub extern fn kx_bench_ms(ctx: ?*Ctx, fonts: ?*Fonts, t: ?*Target, scene: c_int, iters: c_int) f64;

// ===========================================================================
// kx_draw v1 — couleurs 0xRRGGBBAA
// ===========================================================================
pub const Paint = opaque {};
pub const Para = opaque {};
pub const Image = opaque {};

pub extern fn kx_paint_new() ?*Paint;
pub extern fn kx_paint_free(p: ?*Paint) void;
pub extern fn kx_paint_color(p: ?*Paint, rgba: u32) void;
pub extern fn kx_paint_alpha(p: ?*Paint, a01: f32) void;
pub extern fn kx_paint_style(p: ?*Paint, style: c_int) void;
pub extern fn kx_paint_stroke_width(p: ?*Paint, w: f32) void;
pub extern fn kx_paint_blend(p: ?*Paint, blend: c_int) void;
pub extern fn kx_paint_gradient(p: ?*Paint, x0: f32, y0: f32, x1: f32, y1: f32, rgba: [*]const u32, pos: ?[*]const f32, n: c_int) void;
pub extern fn kx_paint_blur(p: ?*Paint, sigma: f32) void;

pub extern fn kx_canvas_clear(t: ?*Target, rgba: u32) c_int;
pub extern fn kx_canvas_save(t: ?*Target) c_int;
pub extern fn kx_canvas_restore(t: ?*Target) c_int;
pub extern fn kx_canvas_save_layer(t: ?*Target, p: ?*const Paint) c_int;
pub extern fn kx_canvas_save_layer_backdrop(t: ?*Target, x: f32, y: f32, w: f32, h: f32, blur_sigma: f32) c_int;
pub extern fn kx_canvas_translate(t: ?*Target, dx: f32, dy: f32) c_int;
pub extern fn kx_canvas_scale(t: ?*Target, sx: f32, sy: f32) c_int;
pub extern fn kx_canvas_rotate(t: ?*Target, deg: f32) c_int;
pub extern fn kx_canvas_clip_rect(t: ?*Target, x: f32, y: f32, w: f32, h: f32) c_int;
pub extern fn kx_canvas_clip_rrect(t: ?*Target, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) c_int;
pub extern fn kx_canvas_draw_rect(t: ?*Target, x: f32, y: f32, w: f32, h: f32, p: ?*const Paint) c_int;
pub extern fn kx_canvas_draw_rrect(t: ?*Target, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32, p: ?*const Paint) c_int;
pub extern fn kx_canvas_draw_circle(t: ?*Target, cx: f32, cy: f32, r: f32, p: ?*const Paint) c_int;
pub extern fn kx_canvas_draw_line(t: ?*Target, x0: f32, y0: f32, x1: f32, y1: f32, p: ?*const Paint) c_int;
pub extern fn kx_canvas_draw_image(t: ?*Target, im: ?*const Image, x: f32, y: f32, w: f32, h: f32, a01: f32) c_int;

pub extern fn kx_para_new(ctx: ?*Ctx, fonts: ?*Fonts) ?*Para;
pub extern fn kx_para_free(p: ?*Para) void;
pub extern fn kx_para_reset(p: ?*Para) void;
pub extern fn kx_para_push_style_families(p: ?*Para, size: f32, rgba: u32, weight: c_int, indices: ?[*]const c_int, count: c_int) c_int;
pub extern fn kx_para_push_style(p: ?*Para, size: f32, rgba: u32, weight: c_int, font_index: c_int) c_int;
pub extern fn kx_para_pop_style(p: ?*Para) c_int;
pub extern fn kx_para_add_text(p: ?*Para, utf8: [*c]const u8) c_int;
pub extern fn kx_para_add_text_n(p: ?*Para, utf8: [*]const u8, len: usize) c_int;
pub extern fn kx_para_max_lines(p: ?*Para, n: c_int) void;
pub extern fn kx_para_align(p: ?*Para, a: c_int) void;
pub extern fn kx_para_layout(p: ?*Para, max_width: f32) c_int;
pub extern fn kx_para_draw(p: ?*Para, t: ?*Target, x: f32, y: f32) c_int;
pub extern fn kx_para_height(p: ?*const Para) f32;
pub extern fn kx_para_max_intrinsic_width(p: ?*const Para) f32;

pub extern fn kx_image_decode(ctx: ?*Ctx, data: ?*const anyopaque, len: usize) ?*Image;
pub extern fn kx_image_size(im: ?*const Image, w: [*c]c_int, h: [*c]c_int) void;
pub extern fn kx_image_free(ctx: ?*Ctx, im: ?*Image) void;

// ===========================================================================
// kx_draw v2 — paths, ombres, gradients supplémentaires, nine-slice.
// ===========================================================================
pub const Path = opaque {};

pub extern fn kx_paint_gradient_radial(p: ?*Paint, cx: f32, cy: f32, r: f32, rgba: [*]const u32, pos: ?[*]const f32, n: c_int) void;
pub extern fn kx_paint_gradient_sweep(p: ?*Paint, cx: f32, cy: f32, start_deg: f32, end_deg: f32, rgba: [*]const u32, pos: ?[*]const f32, n: c_int) void;
pub extern fn kx_paint_stroke_cap(p: ?*Paint, cap: c_int) void;
pub extern fn kx_paint_stroke_join(p: ?*Paint, join: c_int) void;
pub extern fn kx_paint_stroke_miter(p: ?*Paint, m: f32) void;
pub extern fn kx_paint_dash(p: ?*Paint, on: f32, off: f32) void;
pub extern fn kx_paint_image_filter_blur(p: ?*Paint, sigma: f32) void;

pub extern fn kx_path_new() ?*Path;
pub extern fn kx_path_free(p: ?*Path) void;
pub extern fn kx_path_reset(p: ?*Path) void;
pub extern fn kx_path_move_to(p: ?*Path, x: f32, y: f32) void;
pub extern fn kx_path_line_to(p: ?*Path, x: f32, y: f32) void;
pub extern fn kx_path_quad_to(p: ?*Path, cx: f32, cy: f32, x: f32, y: f32) void;
pub extern fn kx_path_cubic_to(p: ?*Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void;
pub extern fn kx_path_conic_to(p: ?*Path, cx: f32, cy: f32, x: f32, y: f32, w: f32) void;
pub extern fn kx_path_arc_to(p: ?*Path, x: f32, y: f32, w: f32, h: f32, start_deg: f32, sweep_deg: f32, force_move: c_int) void;
pub extern fn kx_path_add_circle(p: ?*Path, cx: f32, cy: f32, r: f32) void;
pub extern fn kx_path_add_rrect(p: ?*Path, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) void;
pub extern fn kx_path_close(p: ?*Path) void;

pub extern fn kx_canvas_draw_path(t: ?*Target, p: ?*const Path, q: ?*const Paint) c_int;
pub extern fn kx_canvas_clip_path(t: ?*Target, p: ?*const Path) c_int;
pub extern fn kx_canvas_draw_oval(t: ?*Target, x: f32, y: f32, w: f32, h: f32, q: ?*const Paint) c_int;
pub extern fn kx_canvas_draw_shadow(t: ?*Target, p: ?*const Path, elev: f32, light_y: f32, ambient: u32, spot: u32, transparent_occ: c_int) c_int;
pub extern fn kx_canvas_draw_image_nine(t: ?*Target, im: ?*const Image, cx: c_int, cy: c_int, cw: c_int, ch: c_int, dx: f32, dy: f32, dw: f32, dh: f32, a01: f32) c_int;

pub fn driverInfo(ctx: *Ctx) []const u8 {
    const p = kx_ctx_driver_info(ctx);
    return if (p == null) "?" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}
