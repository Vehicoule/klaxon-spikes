// main.zig — application W0 : pilote le shim kx_skia depuis Zig (wasm32-emscripten).
// La boucle est pilotée par JS (rAF) via les exports kx_step_* : les readbacks
// Graphite sont asynchrones et ne peuvent pas être attendus en C++ sans ASYNCIFY.
const std = @import("std");

const kx_ctx = opaque {};
const kx_target = opaque {};
const kx_readback = opaque {};
const kx_fonts = opaque {};

extern "c" fn kx_ctx_create_graphite_webgpu() ?*kx_ctx;
extern "c" fn kx_ctx_create_ganesh_webgl(sel: ?[*:0]const u8) ?*kx_ctx;
extern "c" fn kx_ctx_create_raster() ?*kx_ctx;
extern "c" fn kx_ctx_backend(c: *kx_ctx) c_int;
extern "c" fn kx_ctx_driver_info(c: *kx_ctx) [*:0]const u8;
extern "c" fn kx_ctx_free(c: *kx_ctx) void;

extern "c" fn kx_target_offscreen(c: *kx_ctx, w: c_int, h: c_int) ?*kx_target;
extern "c" fn kx_target_free(t: *kx_target) void;
extern "c" fn kx_scene_draw(c: *kx_ctx, f: ?*kx_fonts, t: *kx_target, scene: c_int, phase: f64) c_int;
extern "c" fn kx_present(c: *kx_ctx, t: *kx_target) c_int;

extern "c" fn kx_fonts_global() ?*kx_fonts;
extern "c" fn kx_fonts_add(f: *kx_fonts, data: [*]const u8, len: usize) c_int;
extern "c" fn kx_fonts_count(f: *kx_fonts) c_int;

extern "c" fn kx_readback_start(c: *kx_ctx, t: *kx_target) ?*kx_readback;
extern "c" fn kx_readback_poll(c: *kx_ctx, rb: *kx_readback) c_int;
extern "c" fn kx_readback_copy(rb: *kx_readback, dst: [*]u8) c_int;
extern "c" fn kx_readback_free(rb: *kx_readback) void;

extern "c" fn kx_bench_ms(c: *kx_ctx, f: ?*kx_fonts, t: *kx_target, scene: c_int, iters: c_int) f64;

// kx_draw v1 (mêmes symboles que le shim natif — port ABI vérifié par link)
const kx_paint = opaque {};
const kx_para = opaque {};
extern "c" fn kx_paint_new() ?*kx_paint;
extern "c" fn kx_paint_free(p: *kx_paint) void;
extern "c" fn kx_paint_color(p: *kx_paint, rgba: u32) void;
extern "c" fn kx_paint_gradient(p: *kx_paint, x0: f32, y0: f32, x1: f32, y1: f32, rgba: [*]const u32, pos: ?[*]const f32, n: c_int) void;
extern "c" fn kx_canvas_clear(t: *kx_target, rgba: u32) c_int;
extern "c" fn kx_canvas_draw_rrect(t: *kx_target, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32, p: ?*const kx_paint) c_int;
extern "c" fn kx_canvas_draw_circle(t: *kx_target, cx: f32, cy: f32, r: f32, p: ?*const kx_paint) c_int;
extern "c" fn kx_para_new(c: *kx_ctx, f: ?*kx_fonts) ?*kx_para;
extern "c" fn kx_para_free(p: *kx_para) void;
extern "c" fn kx_para_push_style(p: *kx_para, size: f32, rgba: u32, weight: c_int, font_index: c_int) c_int;
extern "c" fn kx_para_add_text(p: *kx_para, utf8: [*]const u8) c_int;
extern "c" fn kx_para_layout(p: *kx_para, max_width: f32) c_int;
extern "c" fn kx_para_draw(p: *kx_para, t: *kx_target, x: f32, y: f32) c_int;

// Fourni côté JS (library_kx.js) : remonte une ligne JSON à collecter.
extern "c" fn kx_report(tag: [*]const u8, tag_len: usize, json: [*]const u8, json_len: usize) void;

// libc emscripten
extern "c" fn malloc(size: usize) ?*anyopaque;
extern "c" fn free(ptr: ?*anyopaque) void;

const N_SCENES = 9;
const W = 480;
const H = 800;
const BENCH_ITERS = 30;

const Backend = struct {
    ctx: *kx_ctx,
    name: []const u8,
};

var state = struct {
    rctx: ?*kx_ctx = null, // raster (référence MAE)
    gctx: ?*kx_ctx = null, // backend sous test
    rt: ?*kx_target = null,
    gt: ?*kx_target = null,
    rb: ?*kx_readback = null,
    rbuf: [W * H * 4]u8 = undefined,
    gbuf: [W * H * 4]u8 = undefined,
    scene: c_int = 0,
    backend_name: [64]u8 = undefined,
    init_ms: f64 = 0,
    done: bool = false,
    err: i32 = 0,
}{};

fn report(tag: []const u8, json: []const u8) void {
    kx_report(tag.ptr, tag.len, json.ptr, json.len);
}

// Appelé par JS une fois le device WebGPU prêt (Module.preinitializedWebGPUDevice)
// ou immédiatement pour backend != webgpu.
export fn kx_start(kind: c_int) c_int {
    state.rctx = kx_ctx_create_raster() orelse {
        report("error", "{\"what\":\"raster ctx create failed\"}");
        return -1;
    };
    state.rt = kx_target_offscreen(state.rctx.?, W, H) orelse return -2;

    state.gctx = switch (kind) {
        1 => kx_ctx_create_ganesh_webgl("#canvas"),
        2 => kx_ctx_create_graphite_webgpu(),
        else => null,
    };
    if (state.gctx == null) {
        report("backend", "{\"status\":\"FAIL\",\"reason\":\"ctx create failed (feature absent?)\"}");
        state.done = true;
        return -3;
    }
    state.gt = kx_target_offscreen(state.gctx.?, W, H) orelse return -4;
    state.scene = 0;
    return 0;
}

// Avance la suite : dessine + lance le readback ; retourne 1 = fini, 0 = en cours.
export fn kx_step() c_int {
    if (state.done) return 1;
    if (state.scene >= N_SCENES) {
        finish();
        return 1;
    }
    const fonts = kx_fonts_global();
    // Raster (référence)
    if (kx_scene_draw(state.rctx.?, fonts, state.rt.?, state.scene, 0.0) != 0) return -1;
    // Backend testé
    if (kx_scene_draw(state.gctx.?, fonts, state.gt.?, state.scene, 0.0) != 0) return -2;

    const bench = kx_bench_ms(state.gctx.?, fonts, state.gt.?, state.scene, BENCH_ITERS);
    const rbench = kx_bench_ms(state.rctx.?, fonts, state.rt.?, state.scene, BENCH_ITERS);

    // Readback raster : synchrone
    const rrb = kx_readback_start(state.rctx.?, state.rt.?) orelse return -3;
    _ = kx_readback_poll(state.rctx.?, rrb);
    if (kx_readback_copy(rrb, &state.rbuf) <= 0) return -4;
    kx_readback_free(rrb);

    // Readback GPU : lancé ici, complété dans kx_poll_readback (rAF)
    state.rb = kx_readback_start(state.gctx.?, state.gt.?) orelse return -5;

    var buf: [256]u8 = undefined;
    const js = std.fmt.bufPrint(&buf,
        "{{\"scene\":{},\"bench_ms\":{d:.3},\"raster_bench_ms\":{d:.3}}}",
        .{ state.scene, bench / BENCH_ITERS, rbench / BENCH_ITERS }) catch return -6;
    report("bench", js);
    return 0;
}

// Pollé chaque rAF jusqu'à 1 : le readback GPU est prêt → calcule la MAE et
// rapporte, puis avance à la scène suivante.
export fn kx_poll_readback() c_int {
    const rb = state.rb orelse return 1; // rien en attente → prêt
    const st = kx_readback_poll(state.gctx.?, rb);
    if (st == 0) return 0; // en attente
    if (st < 0) {
        kx_readback_free(rb);
        state.rb = null;
        state.err = -1;
        return -1;
    }
    if (kx_readback_copy(rb, &state.gbuf) <= 0) {
        kx_readback_free(rb);
        state.rb = null;
        return -2;
    }
    kx_readback_free(rb);
    state.rb = null;

    // MAE RGBA moyen + compteur de pixels non-blancs (garde-fou blanc-vs-blanc).
    var acc: u64 = 0;
    var nw_r: u32 = 0;
    var nw_g: u32 = 0;
    var i: usize = 0;
    while (i < W * H * 4) : (i += 4) {
        const a: i32 = @intCast(state.rbuf[i]);
        const b: i32 = @intCast(state.gbuf[i]);
        const ag: i32 = @intCast(state.rbuf[i + 1]);
        const bg: i32 = @intCast(state.gbuf[i + 1]);
        const ab: i32 = @intCast(state.rbuf[i + 2]);
        const bb: i32 = @intCast(state.gbuf[i + 2]);
        acc += @intCast(@abs(a - b) + @abs(ag - bg) + @abs(ab - bb));
        if (a < 250 or ag < 250 or ab < 250) nw_r += 1;
        if (b < 250 or bg < 250 or bb < 250) nw_g += 1;
    }
    const mae = @as(f64, @floatFromInt(acc)) / @as(f64, W * H * 3);
    var buf: [256]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "{{\"scene\":{},\"mae\":{d:.4},\"nw_r\":{},\"nw_g\":{}}}", .{ state.scene, mae, nw_r, nw_g }) catch return -3;
    report("mae", js);
    state.scene += 1;
    return 1;
}

fn finish() void {
    if (state.done) return;
    state.done = true;
    drawSmoke();
    const info = std.mem.span(kx_ctx_driver_info(state.gctx.?));
    var buf: [384]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "{{\"status\":\"PASS\",\"driver\":\"{s}\",\"fonts\":{}}}",
        .{ info, kx_fonts_count(kx_fonts_global().?) }) catch return;
    report("done", js);
}

// Dessine via l'API v1 sur le contexte RASTER (preuve link+run wasm) :
// rrect dégradé + cercle + paragraphe, readback sync, compte les non-blancs.
fn drawSmoke() void {
    const c = state.rctx orelse return;
    const t = state.rt orelse return;
    const p = kx_paint_new() orelse return;
    defer kx_paint_free(p);
    _ = kx_canvas_clear(t, 0x16161EFF);
    kx_paint_gradient(p, 20, 20, 460, 220,
        &[2]u32{ 0x8E2DE2FF, 0x4A00E0FF }, null, 2);
    if (kx_canvas_draw_rrect(t, 20, 20, 440, 200, 18, 18, p) != 0) {
        report("draw_smoke", "{\"status\":\"FAIL\",\"why\":\"draw_rrect\"}");
        return;
    }
    kx_paint_color(p, 0xFFFFFFFF);
    _ = kx_canvas_draw_circle(t, 240, 120, 12, p);
    if (kx_fonts_count(kx_fonts_global().?) > 0) {
        if (kx_para_new(c, kx_fonts_global())) |para| {
            defer kx_para_free(para);
            _ = kx_para_push_style(para, 26, 0xF5F5FAFF, 700, -1);
            _ = kx_para_add_text(para, "kx_draw wasm");
            _ = kx_para_layout(para, 400);
            _ = kx_para_draw(para, t, 20, 240);
        }
    }
    const rb = kx_readback_start(c, t) orelse return;
    defer kx_readback_free(rb);
    _ = kx_readback_poll(c, rb);
    if (kx_readback_copy(rb, &state.rbuf) <= 0) {
        report("draw_smoke", "{\"status\":\"FAIL\",\"why\":\"readback\"}");
        return;
    }
    var nw: u32 = 0;
    var i: usize = 0;
    while (i < W * H * 4) : (i += 4) {
        if (state.rbuf[i] != 0x16 or state.rbuf[i + 1] != 0x16 or state.rbuf[i + 2] != 0x1E) nw += 1;
    }
    var buf: [128]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, "{{\"status\":\"{s}\",\"nw\":{}}}",
        .{ if (nw > 1000) "PASS" else "FAIL", nw }) catch return;
    report("draw_smoke", js);
}

// Allocation exposée à JS pour y écrire les fontes téléchargées.
export fn kx_alloc(len: usize) ?[*]u8 {
    return @ptrCast(malloc(len));
}

export fn kx_add_font(ptr: [*]const u8, len: usize) c_int {
    return kx_fonts_add(kx_fonts_global().?, ptr, len);
}

export fn kx_free_alloc(ptr: [*]u8) void {
    free(@ptrCast(ptr));
}

pub fn main() void {}
