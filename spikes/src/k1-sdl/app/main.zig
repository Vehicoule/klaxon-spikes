// K1-linux : hôte SDL3 (Zig 0.17, bindings translate-c) + kx Ganesh-GL.
// Prouve : fenêtre SDL3 + rendu Skia onscreen + lifecycle (resize/expose/
// minimize) + 0 frame au repos + first-frame + driver réel.
// Usage: k1-sdl <scene:int> <frames:int> <outdir>
const std = @import("std");
const c = @import("kx_sdl.zig");

var frames_budget: i64 = 120;
var scene: c_int = 1;
var rest_mode = false;

var gp_calls: u32 = 0;

fn getProc(name: [*c]const u8) callconv(.c) ?*anyopaque {
    gp_calls += 1;
    // GLX : pas de display EGL -> ne pas exposer eglQueryString/eglGetCurrentDisplay
    // (Skia appellerait eglQueryString(EGL_NO_DISPLAY) puis dereferait NULL).
    const n = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    if (std.mem.startsWith(u8, n, "egl")) {
        if (gp_calls < 8) std.debug.print("getProc #{d} {s} -> masked\n", .{ gp_calls, n });
        return null;
    }
    const p = c.SDL_GL_GetProcAddress(name);
    if (gp_calls < 8 or p == null) {
        std.debug.print("getProc #{d} {s} -> {x}\n", .{ gp_calls, name, @intFromPtr(p) });
    }
    return @ptrCast(@constCast(p));
}

fn nowUs(io: std.Io) i96 {
    return @divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, 1000);
}

pub fn main(init: std.process.Init) !void {
    var argv = std.process.Args.Iterator.init(init.minimal.args);
    var outdir: []const u8 = "out";
    var i: usize = 0;
    while (argv.next()) |a| : (i += 1) {
        if (i == 1) scene = try std.fmt.parseInt(c_int, a, 10);
        if (i == 2) frames_budget = try std.fmt.parseInt(i64, a, 10);
        if (i == 3) outdir = a;
        if (i == 4) rest_mode = std.mem.eql(u8, a, "rest");
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);

    const win = c.SDL_CreateWindow("k1-sdl", 800, 600,
        c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_RESIZABLE) orelse return error.NoWindow;
    const gl = c.SDL_GL_CreateContext(win);
    if (gl == null) return error.NoGL;
    _ = c.SDL_GL_MakeCurrent(win, gl);
    _ = c.SDL_GL_SetSwapInterval(1);

    const ctx = c.kx_ctx_create_ganesh_gl_current(getProc) orelse return error.NoKx;
    const fonts = c.kx_fonts_global() orelse return error.NoFonts;

    var w: c_int = 800;
    var h: c_int = 600;
    var tgt = c.kx_target_onscreen_gl(ctx, w, h) orelse return error.NoTarget;

    var ev: c.SDL_Event = undefined;
    var running = true;
    var dirty = true;
    var presented: i64 = 0;
    var resizes: i64 = 0;
    var exposes: i64 = 0;
    var minimized = false;
    var minimized_iters: i64 = 0;
    var idle_iters: i64 = 0;
    var first_ms: f64 = -1;
    var sum_ms: f64 = 0;

    const t0 = nowUs(init.io);
    while (running and (rest_mode and @divTrunc(nowUs(init.io) - t0, 1_000_000) < 2 or !rest_mode and presented < frames_budget)) {
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_RESIZED => {
                    w = ev.window.data1;
                    h = ev.window.data2;
                    c.kx_target_free(tgt);
                    tgt = c.kx_target_onscreen_gl(ctx, w, h) orelse return error.NoTarget;
                    resizes += 1;
                    dirty = true;
                },
                c.SDL_EVENT_WINDOW_EXPOSED => { exposes += 1; dirty = true; },
                c.SDL_EVENT_WINDOW_MINIMIZED => minimized = true,
                c.SDL_EVENT_WINDOW_RESTORED => { minimized = false; dirty = true; },
                else => {},
            }
        }
        if (minimized) { minimized_iters += 1; c.SDL_Delay(16); continue; }
        if (!dirty) { idle_iters += 1; c.SDL_Delay(4); continue; }
        const f0 = nowUs(init.io);
        _ = c.kx_scene_draw(ctx, fonts, tgt, scene,
            @as(f64, @floatFromInt(@mod(presented, 120))) / 120.0);
        _ = c.kx_present(ctx, tgt);
        _ = c.SDL_GL_SwapWindow(win);
        const dt = @as(f64, @floatFromInt(nowUs(init.io) - f0)) / 1000.0;
        if (first_ms < 0) first_ms = dt;
        sum_ms += dt;
        presented += 1;
        dirty = !rest_mode; // rest: ne re-rend que sur événement
    }
    if (rest_mode) running = true; // sortie par durée ci-dessous
    const total_ms = @divTrunc(nowUs(init.io) - t0, 1000);

    const driver = c.kx_ctx_driver_info(ctx);
    const avg = if (presented > 0) sum_ms / @as(f64, @floatFromInt(presented)) else 0;
    var buf: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf,
        "{{\"tool\":\"k1-sdl-zig\",\"backend\":\"{s}\",\"scene\":{},\"frames\":{},\"total_ms\":{},\"avg_frame_ms\":{d:.3},\"first_frame_ms\":{d:.3},\"resizes\":{},\"exposes\":{},\"minimized_iters\":{},\"idle_iters\":{}}}",
        .{ driver, scene, presented, total_ms, avg, first_ms, resizes, exposes, minimized_iters, idle_iters });
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), init.io, outdir);
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/k1-linux-s{}.json", .{ outdir, scene }) catch unreachable;
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), init.io, .{ .sub_path = path, .data = json });
    std.debug.print("{s}\n", .{json});
}
