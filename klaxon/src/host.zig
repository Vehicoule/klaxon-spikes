// host.zig — couche plateforme Klaxon : fenêtre SDL3 + boucle dirty-flag +
// lifecycle + GL onscreen. Zig 0.17. ADR-0004 : événements typés, jamais de
// JNI/objc/JS dans le domaine.
const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl.zig");
const kx = @import("kx.zig");
const ui = @import("ui.zig");

pub const is_wasm = builtin.os.tag == .emscripten;
extern fn emscripten_get_now() f64; // ms depuis load (monotone)

/// Chemin de présentation : GL = SDL_GL_SwapWindow ; dawn = le shim présente
/// la swapchain dans kx_present (DXGI/Metal/etc). canvas wasm = gl==null.
pub const GpuMode = enum { gl, dawn, metal };
pub const DawnVariant = enum { d3d12, vulkan };

pub const Event = union(enum) {
    quit,
    resized: struct { w: i32, h: i32 },
    exposed,
    minimized,
    restored,
    will_enter_background,
    did_enter_background,
    will_enter_foreground,
    did_enter_foreground,
    low_memory,
    key_down: struct { key: u32, mod: u16 },
    key_up: struct { key: u32, mod: u16 },
    text_input: []const u8,
    /// Composition IME (pre-edit) : texte en cours + caret dans ce texte.
    text_editing: struct { text: []const u8, start: i32, length: i32 },
    pointer_down: struct { x: f32, y: f32, button: u8 },
    pointer_up: struct { x: f32, y: f32, button: u8 },
    pointer_move: struct { x: f32, y: f32 },
    /// dx/dy = delta molette (crans SDL), x/y = position souris au moment
    /// de l'event (nécessaire au hit-test scrollable).
    wheel: struct { dx: f32, dy: f32, x: f32, y: f32 },
};

pub const Stats = struct {
    frames: i64 = 0,
    resizes: i64 = 0,
    exposes: i64 = 0,
    minimized_iters: i64 = 0,
    idle_iters: i64 = 0,
    first_frame_ms: f64 = -1,
    ttff_ms: f64 = -1,            // boot→1er présent (time-to-first-frame, cible 200)
    sum_frame_ms: f64 = 0,
    frame_ms_ring: [2048]f32 = undefined, // p99 sur les 2048 premières frames
    interval_ms_ring: [2048]f32 = undefined, // pacing : présent→présent
    last_present_us: i96 = -1,
    ring_i: usize = 0,
    pub fn avgFrameMs(self: Stats) f64 {
        return if (self.frames > 0) self.sum_frame_ms / @as(f64, @floatFromInt(self.frames)) else 0;
    }
    /// p99 des frames échantillonnées (≤2048) — gate scroll de l'ADR-0008.
    pub fn p99FrameMs(self: *const Stats) f64 {
        const n: usize = @intCast(@min(self.frames, 2048));
        if (n == 0) return 0;
        var tmp: [2048]f32 = undefined;
        @memcpy(tmp[0..n], self.frame_ms_ring[0..n]);
        std.mem.sort(f32, tmp[0..n], {}, std.sort.asc(f32));
        return tmp[n * 99 / 100];
    }
    /// p99 des intervalles présent→présent (jitter pacing, gate V1).
    pub fn p99IntervalMs(self: *const Stats) f64 {
        const n: usize = @intCast(@min(self.ring_i, 2048));
        if (n < 2) return 0;
        var tmp: [2048]f32 = undefined;
        @memcpy(tmp[0..n], self.interval_ms_ring[0..n]);
        std.mem.sort(f32, tmp[0..n], {}, std.sort.asc(f32));
        return tmp[n * 99 / 100];
    }
    /// Pic RSS du processus en KiB (ru_maxrss) — gate mémoire ADR-0008.
    /// Cross-plateforme : Windows exposera GetProcessMemoryInfo en V1.
    pub fn peakRssKb() isize {
        if (comptime builtin.os.tag == .windows) return 0;
        const v = std.posix.getrusage(std.posix.rusage.SELF).maxrss;
        // Apple : ru_maxrss est en BYTES (Linux : KiB) — mesuré en V1-iOS.
        if (comptime builtin.os.tag.isDarwin()) return @divTrunc(v, 1024);
        return v;
    }
};

// Le get_proc masque "egl*" : sous GLX (display EGL absente), Skia
// appellerait eglQueryString(EGL_NO_DISPLAY) et déréférencerait NULL
// dans GrGLExtensions::init (piège mesuré dans K1). Sur Android/EGL réel,
// réactiver via policy.
const is_android = builtin.abi == .android;
var gp_mask_egl: bool = !is_android;
fn glGetProc(name: [*c]const u8) callconv(.c) ?*anyopaque {
    const n = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    if (gp_mask_egl and std.mem.startsWith(u8, n, "egl")) return null;
    return @ptrCast(@constCast(sdl.SDL_GL_GetProcAddress(name)));
}

pub const Host = struct {
    win: *sdl.Window,
    gl: ?*sdl.GLContext, // non-null seulement si backend GL
    hwnd: ?*anyopaque = null, // handle natif (HWND) pour la swapchain dawn
    view: ?*sdl.MetalView = null, // CAMetalView pour le backend metal (macOS/iOS)
    scale: f64 = 1,            // contentsScale dérivé px/points (retina)
    mode: GpuMode = .gl,
    ctx: *kx.Ctx,
    fonts: ?*kx.Fonts,
    target: ?*kx.Target,
    io: std.Io,
    minimized: bool = false,
    stats: Stats = .{},
    dirty: bool = true,
    ios_mapped_us: i128 = -1, // instant où la view UIKit est attachée à sa fenêtre
    boot_t0_us: i96 = -1,     // marque boot la plus ancienne (init* ou markBoot)

    /// Recule la marque boot (entrée du process/main) — ttff_ms la prend
    /// en compte au premier présent. Les init* la posent déjà ; markBoot
    /// permet à l'app de couvrir aussi son propre démarrage.
    pub fn markBoot(self: *Host, t0_us: i96) void {
        if (self.boot_t0_us < 0 or t0_us < self.boot_t0_us) self.boot_t0_us = t0_us;
    }

    pub fn initGlWindow(io: std.Io, title: [*c]const u8, w: c_int, h: c_int) !Host {
        const t0 = nowUs(io); // marque ttff la plus ancienne côté framework
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInit;
        if (comptime is_android) {
            // Android : ES3 + stencil (clips Skia) + fullscreen implicite.
            _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_ES);
            _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
            _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 0);
        } else {
            _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, 2);
            _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, 0);
        }
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_STENCIL_SIZE, 8);
        const flags: u64 = sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_RESIZABLE |
            (if (comptime is_android) sdl.SDL_WINDOW_FULLSCREEN else 0);
        const win = sdl.SDL_CreateWindow(title, w, h, flags) orelse return error.NoWindow;
        const gl = sdl.SDL_GL_CreateContext(win) orelse return error.NoGL;
        _ = sdl.SDL_GL_MakeCurrent(win, gl);
        _ = sdl.SDL_GL_SetSwapInterval(1);
        const ctx = kx.kx_ctx_create_ganesh_gl_current(glGetProc) orelse return error.NoKx;
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(win, &pw, &ph);
        const tgt = kx.kx_target_onscreen_gl(ctx, pw, ph) orelse return error.NoTarget;
        var hwnd: ?*anyopaque = null;
        if (comptime builtin.os.tag == .windows) {
            hwnd = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(win),
                sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
        }
        return .{
            .win = win, .gl = gl, .hwnd = hwnd, .ctx = ctx,
            .fonts = kx.kx_fonts_global(), .target = tgt, .io = io,
            .boot_t0_us = t0,
        };
    }

    /// Variante Apple : SDL_WINDOW_METAL + SDL_Metal_CreateView → CAMetalLayer
    /// → graphite-metal. Drawable acquis par frame (kx_acquire_surface),
    /// présenté via kx_present (presentDrawable). Valable macOS ET iOS.
    pub fn initMetalWindow(io: std.Io, title: [*c]const u8, w: c_int, h: c_int) !Host {
        if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
            const t0 = nowUs(io);
            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInit;
            const win = sdl.SDL_CreateWindow(title, w, h, sdl.SDL_WINDOW_METAL |
                sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return error.NoWindow;
            const view = sdl.SDL_Metal_CreateView(win) orelse return error.NoMetalView;
            const ctx = kx.kx_ctx_create_graphite_metal() orelse return error.NoKx;
            var host: Host = .{
                .win = win, .gl = null, .view = view, .mode = .metal, .ctx = ctx,
                .fonts = kx.kx_fonts_global(), .target = null, .io = io,
                .boot_t0_us = t0,
            };
            _ = host.makeMetalTarget() orelse return error.NoTarget;
            // Text input activé dès l'init (IME/macOS compose inline).
            _ = sdl.SDL_StartTextInput(win);
            // Hit-test AX : class_addMethod sur SDL_MetalView si la classe
            // n'implémente pas déjà (retour 1/0/-1 consigné par le shim).
            _ = kx.kx_a11y_install_hittest(host.view);
            return host;
        } else {
            return error.Unsupported;
        }
    }

    /// (Re)crée la cible onscreen metal sur le layer courant, taille pixels
    /// + contentsScale dérivé (pw/lw). Libère la cible précédente.
    fn makeMetalTarget(self: *Host) ?*kx.Target {
        if (comptime !(builtin.os.tag == .macos or builtin.os.tag == .ios)) return null;
        const layer = sdl.SDL_Metal_GetLayer(self.view) orelse return null;
        var pw: c_int = 0;
        var ph: c_int = 0;
        var lw: c_int = 0;
        var lh: c_int = 0;
        _ = sdl.SDL_GetWindowSizeInPixels(self.win, &pw, &ph);
        _ = sdl.SDL_GetWindowSize(self.win, &lw, &lh);
        if (pw <= 0 or ph <= 0 or lw <= 0) return null;
        self.scale = @as(f64, @floatFromInt(pw)) / @as(f64, @floatFromInt(lw));
        const t = kx.kx_target_onscreen_metal(self.ctx, layer, pw, ph, self.scale) orelse return null;
        if (self.target) |old| kx.kx_target_free(old);
        self.target = t;
        return t;
    }

    /// Variante wasm/emscripten : fenêtre SDL3 (→ canvas #canvas) SANS contexte
    /// GL SDL — c'est le shim kx qui possède le contexte WebGL2 du canvas
    /// (kx_target_canvas dessine dans le FBO 0 ; le browser présente à rAF).
    /// SDL donne juste les événements (pointeur, clavier→TEXT_INPUT, wheel).
    pub fn initCanvasWindow(title: [*c]const u8, w: c_int, h: c_int) !Host {
        const t0 = nowUs(undefined); // wasm : horloge navigateur, pas d'io
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInit;
        const win = sdl.SDL_CreateWindow(title, w, h, sdl.SDL_WINDOW_RESIZABLE) orelse return error.NoWindow;
        const ctx = kx.kx_ctx_create_ganesh_webgl("#canvas") orelse return error.NoKx;
        const tgt = kx.kx_target_canvas(ctx, "#canvas", w, h) orelse return error.NoTarget;
        return .{
            .win = win, .gl = null, .ctx = ctx,
            .fonts = kx.kx_fonts_global(), .target = tgt, .io = undefined,
            .boot_t0_us = t0,
        };
    }

    /// Variante Windows : fenêtre SDL SANS flag GL → HWND natif → swapchain
    /// WebGPU/Dawn (d3d12 primaire, vulkan secondaire). kx_present fait
    /// flush+submit+Present() côté shim ; SDL ne sert que fenêtre+events.
    pub fn initDawnWindow(io: std.Io, title: [*c]const u8, w: c_int, h: c_int,
                          variant: DawnVariant) !Host {
        if (comptime builtin.os.tag == .windows) {
            const t0 = nowUs(io);
            if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SdlInit;
            const win = sdl.SDL_CreateWindow(title, w, h, sdl.SDL_WINDOW_RESIZABLE) orelse return error.NoWindow;
            const props = sdl.SDL_GetWindowProperties(win);
            const hwnd = sdl.SDL_GetPointerProperty(props, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse return error.NoHwnd;
            const ctx = switch (variant) {
                .d3d12 => kx.kx_ctx_create_graphite_dawn_d3d12(),
                .vulkan => kx.kx_ctx_create_graphite_dawn_vulkan(),
            } orelse return error.NoKx;
            var pw: c_int = 0;
            var ph: c_int = 0;
            _ = sdl.SDL_GetWindowSizeInPixels(win, &pw, &ph);
            const tgt = kx.kx_target_onscreen_dawn(ctx, hwnd, pw, ph) orelse return error.NoTarget;
            return .{
                .win = win, .gl = null, .hwnd = hwnd, .mode = .dawn,
                .ctx = ctx, .fonts = kx.kx_fonts_global(), .target = tgt, .io = io,
                .boot_t0_us = t0,
            };
        } else {
            return error.Unsupported;
        }
    }

    pub fn deinit(self: *Host) void {
        if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
            if (self.view) |v| sdl.SDL_Metal_DestroyView(v);
        }
        if (self.target) |t| kx.kx_target_free(t);
        kx.kx_ctx_free(self.ctx);
        if (self.gl) |g| _ = sdl.SDL_GL_DestroyContext(g);
        sdl.SDL_DestroyWindow(self.win);
        sdl.SDL_Quit();
    }

    pub fn backend(self: *Host) kx.Backend {
        return kx.kx_ctx_backend(self.ctx);
    }
    pub fn driverInfo(self: *Host) []const u8 {
        return kx.driverInfo(self.ctx);
    }

    /// Branche le callback d'activation AT (action 0 = press). L'app
    /// fournit un handler `fn(ctx, node, action)` — le trampoline traduit
    /// l'ident opaque en *ui.Node (le pointeur passé à sync_item).
    /// No-op hors Apple tant que les autres ponts n'ont pas d'actions.
    pub fn setA11yActionHandler(self: *Host,
        cb: ?*const fn (ctx: ?*anyopaque, node: *ui.Node, action: c_int) void,
        ctx: ?*anyopaque) void {
        if (comptime !(builtin.os.tag == .macos or builtin.os.tag == .ios or
                       builtin.os.tag == .windows or is_android or
                       builtin.os.tag == .linux)) return;
        a11y_action_cb = cb;
        a11y_action_ctx = ctx;
        if (comptime builtin.os.tag == .linux and !is_android) {
            // Linux : provider AT-SPI global (pas de view — sd-bus).
            if (cb != null)
                kx.kx_a11y_set_action_handler(null, a11yActionTrampoline, null)
            else
                kx.kx_a11y_set_action_handler(null, null, null);
        } else if (comptime is_android) {
            // Android : le handler est stocké côté JNI (view inutilisée).
            if (cb != null)
                kx.kx_a11y_set_action_handler(null, a11yActionTrampoline, null)
            else
                kx.kx_a11y_set_action_handler(null, null, null);
        } else if (comptime builtin.os.tag == .windows) {
            // Windows : view absente — le bridge UIA est keyed par HWND.
            if (cb != null)
                kx.kx_a11y_set_action_handler(self.hwnd, a11yActionTrampoline, null)
            else
                kx.kx_a11y_set_action_handler(self.hwnd, null, null);
        } else if (self.view) |v| {
            if (cb != null)
                kx.kx_a11y_set_action_handler(v, a11yActionTrampoline, null)
            else
                kx.kx_a11y_set_action_handler(v, null, null);
        }
    }

    /// Pont a11y natif : pousse l'arbre sémantique plat vers le bridge
    /// plateforme (NSAccessibility macOS, UIAccessibility iOS, UIA Windows
    /// via HWND, TalkBack Android via le provider JNI, AT-SPI Linux via
    /// sd-bus — view inutilisée sur les deux derniers).
    /// Appeler quand l'arbre change (mutations labels/bounds/focus incluses —
    /// le shim ne notifie que si l'arbre a réellement muté). No-op hors
    /// plateformes pontées (web = séparé côté JS).
    pub fn syncA11y(self: *Host, root: *const ui.Node, alloc: std.mem.Allocator) !void {
        if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
            if (self.view) |v| try ui.pushA11y(v, self.scale, root, alloc);
        } else if (comptime is_android or builtin.os.tag == .linux) {
            // Android : provider JNI sur la SurfaceView ; Linux : provider
            // AT-SPI sd-bus global — param view ignoré dans les deux cas.
            try ui.pushA11y(null, 1, root, alloc);
        } else if (comptime builtin.os.tag == .windows) {
            if (self.hwnd) |h| try ui.pushA11y(h, self.scale, root, alloc);
        }
    }

    /// Dispatch d'un event interne : lifecycle/dirty. false = quit.
    fn handleEvent(self: *Host, e: Event) bool {
        switch (e) {
            .quit => return false,
            .resized => |r| {
                if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
                    if (self.mode == .metal) {
                        _ = self.makeMetalTarget();
                        self.stats.resizes += 1;
                        self.dirty = true;
                        return true;
                    }
                }
                if (self.target) |t| kx.kx_target_free(t);
                self.target = blk: {
                    if (is_wasm) break :blk kx.kx_target_canvas(self.ctx, "#canvas", r.w, r.h);
                    if (comptime builtin.os.tag == .windows) {
                        if (self.mode == .dawn) break :blk kx.kx_target_onscreen_dawn(self.ctx, self.hwnd, r.w, r.h);
                    }
                    break :blk kx.kx_target_onscreen_gl(self.ctx, r.w, r.h);
                };
                self.stats.resizes += 1;
                self.dirty = true;
            },
            .exposed => { self.stats.exposes += 1; self.dirty = true; },
            .minimized => self.minimized = true,
            .restored => { self.minimized = false; self.dirty = true; },
            else => self.dirty = true,
        }
        return true;
    }

    /// Pompe SDL_PollEvent → événements typés. Renvoie false sur quit.
    /// `on_event` optionnel : callback métier par event.
    pub fn pollEvents(self: *Host, on_event: ?*const fn (Event) void) bool {
        var ev: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&ev)) {
            const e = translate(ev, @floatCast(self.scale)) orelse continue;
            if (on_event) |f| f(e);
            if (!self.handleEvent(e)) return false;
        }
        return true;
    }

    pub const Step = enum { idle, drew, quit };

    /// Une itération de boucle. Au repos (!dirty) : attend un event via
    /// SDL_WaitEventTimeout(wait_ms) au lieu de spinner (SDL_AppIterate
    /// CPU-100% d'Android, piège mesuré) — les events reçus passent par le
    /// même dispatch que pollEvents. wait_ms=0 → Delay fixe.
    /// ADR-0002 : rendu sur invalidation — au repos aucune frame.
    pub fn step(self: *Host, draw: *const fn (*Host) void,
                on_event: ?*const fn (Event) void, wait_ms: c_int) Step {
        if (self.minimized) { self.stats.minimized_iters += 1; sdl.SDL_Delay(16); return .idle; }
        if (comptime builtin.os.tag == .linux and builtin.abi != .android) {
            // AT-SPI : draine les requêtes D-Bus du provider (les ATs nous
            // appellent à tout moment — pas d'attente, juste un pump).
            _ = kx.kx_a11y_pump();
        }
        if (!self.dirty) {
            self.stats.idle_iters += 1;
            var ev: sdl.SDL_Event = undefined;
            if (sdl.SDL_WaitEventTimeout(&ev, wait_ms)) {
                if (translate(ev, @floatCast(self.scale))) |e| {
                    if (on_event) |f| f(e);
                    if (!self.handleEvent(e)) return .quit;
                }
            }
            return .idle;
        }
        const t0 = nowUs(self.io);
        self.dirty = false; // consommé avant draw : le métier peut re-dirty dedans
        draw(self);
        // Swap GL uniquement : wasm = le browser présente le canvas à rAF ;
        // dawn = kx_present a déjà fait Present() dans draw().
        if (!is_wasm and self.gl != null) _ = sdl.SDL_GL_SwapWindow(self.win);
        const now_us = nowUs(self.io);
        const dt = @as(f64, @floatFromInt(now_us - t0)) / 1000.0;
        if (self.stats.first_frame_ms < 0) {
            self.stats.first_frame_ms = dt;
            // ttff = marque boot → ce premier présent (draw+swap compris).
            if (self.boot_t0_us >= 0)
                self.stats.ttff_ms = @as(f64, @floatFromInt(now_us - self.boot_t0_us)) / 1000.0;
        }
        self.stats.sum_frame_ms += dt;
        const i = self.stats.ring_i;
        if (i < self.stats.frame_ms_ring.len)
            self.stats.frame_ms_ring[i] = @floatCast(dt);
        if (i < self.stats.interval_ms_ring.len)
            self.stats.interval_ms_ring[i] = @floatCast(
                if (self.stats.last_present_us < 0) 0.0
                else @as(f64, @floatFromInt(now_us - self.stats.last_present_us)) / 1000.0);
        self.stats.last_present_us = now_us;
        self.stats.ring_i += 1;
        self.stats.frames += 1;
        if (comptime builtin.os.tag == .ios) {
            // iOS : UIKit ne poste ni RESIZED ni EXPOSED au démarrage ; les
            // présents faits avant que la view SDL soit attachée à sa
            // UIWindow sont perdus → écran noir persistant (mesuré). On
            // produit tant que view.window == nil, + ~200ms pour couvrir
            // la fin de la transition d'apparence.
            if (self.ios_mapped_us < 0) {
                const w = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(self.win), "SDL.window.uikit.window", null);
                if (w != null and kx.kx_ios_window_mapped(w) != 0)
                    self.ios_mapped_us = nowUs(self.io);
                self.dirty = true;
            } else if (nowUs(self.io) - self.ios_mapped_us < 200_000)
                self.dirty = true;
        }
        return .drew;
    }

    pub fn presentTarget(self: *Host) void {
        if (self.target) |t| _ = kx.kx_present(self.ctx, t);
    }
};

/// ptr_scale = px/points (self.scale) — iOS SDL donne les coords souris en
/// points logiques alors que le canvas/hit-test travaille en pixels device
/// (@3x → facteur 3). Desktop 1× → identité.
fn translate(ev: sdl.SDL_Event, ptr_scale: f32) ?Event {
    return switch (ev.type) {
        sdl.SDL_EVENT_QUIT => .quit,
        // retina/HiDPI : taille PIXELS peut changer sans event RESIZED ;
        // macOS : CAMetalLayer suit la vue — même traitement qu'un resize.
        sdl.SDL_EVENT_WINDOW_RESIZED, sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        sdl.SDL_EVENT_WINDOW_METAL_VIEW_RESIZED
        => .{ .resized = .{ .w = ev.window.data1, .h = ev.window.data2 } },
        sdl.SDL_EVENT_WINDOW_EXPOSED => .exposed,
        sdl.SDL_EVENT_WINDOW_MINIMIZED => .minimized,
        sdl.SDL_EVENT_WINDOW_RESTORED => .restored,
        sdl.SDL_EVENT_WILL_ENTER_BACKGROUND => .will_enter_background,
        sdl.SDL_EVENT_DID_ENTER_BACKGROUND => .did_enter_background,
        sdl.SDL_EVENT_WILL_ENTER_FOREGROUND => .will_enter_foreground,
        sdl.SDL_EVENT_DID_ENTER_FOREGROUND => .did_enter_foreground,
        sdl.SDL_EVENT_LOW_MEMORY => .low_memory,
        sdl.SDL_EVENT_KEY_DOWN => .{ .key_down = .{ .key = ev.key.key, .mod = ev.key.mod } },
        sdl.SDL_EVENT_KEY_UP => .{ .key_up = .{ .key = ev.key.key, .mod = ev.key.mod } },
        sdl.SDL_EVENT_TEXT_EDITING => .{ .text_editing = .{
            .text = if (ev.edit.text == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(ev.edit.text))),
            .start = ev.edit.start,
            .length = ev.edit.length,
        } },
        sdl.SDL_EVENT_TEXT_INPUT => .{ .text_input = if (ev.text.text == null) "" else std.mem.span(@as([*:0]const u8, @ptrCast(ev.text.text))) },
        sdl.SDL_EVENT_MOUSE_BUTTON_DOWN => .{ .pointer_down = .{ .x = ev.button.x * ptr_scale, .y = ev.button.y * ptr_scale, .button = ev.button.button } },
        sdl.SDL_EVENT_MOUSE_BUTTON_UP => .{ .pointer_up = .{ .x = ev.button.x * ptr_scale, .y = ev.button.y * ptr_scale, .button = ev.button.button } },
        sdl.SDL_EVENT_MOUSE_MOTION => .{ .pointer_move = .{ .x = ev.motion.x * ptr_scale, .y = ev.motion.y * ptr_scale } },
        sdl.SDL_EVENT_MOUSE_WHEEL => .{ .wheel = .{ .dx = ev.wheel.x, .dy = ev.wheel.y, .x = ev.wheel.mouse_x * ptr_scale, .y = ev.wheel.mouse_y * ptr_scale } },
        else => null,
    };
}

pub fn nowUs(io: std.Io) i96 {
    if (is_wasm) return @intFromFloat(emscripten_get_now() * 1000.0);
    return @divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, 1000);
}

// Handler AT enregistré par l'app (Apple only — voir setA11yActionHandler).
var a11y_action_cb: ?*const fn (ctx: ?*anyopaque, node: *ui.Node, action: c_int) void = null;
var a11y_action_ctx: ?*anyopaque = null;
fn a11yActionTrampoline(ctx: ?*anyopaque, ident: ?*anyopaque, action: c_int) callconv(.c) void {
    _ = ctx; // le ctx app vit dans a11y_action_ctx (le shim passe le sien)
    const cb = a11y_action_cb orelse return;
    // ident = le *const Node passé à sync_item (SemItem.node est const).
    const node: *ui.Node = @ptrCast(@alignCast(@constCast(ident orelse return)));
    cb(a11y_action_ctx, node, action);
}
