// vehicoule/main.zig — V0 : lecteur musical local.
// Scan via le plugin scanner.wasm sandboxé (WAMR + policy scan:<dir>),
// décodage dr_libs → SDL_AudioStream (push, resample natif), UI klaxon.
// Args : [--dir <path>] [--frames N] [--secs N] [--theme dark|light]
const std = @import("std");
const builtin = @import("builtin");
const k = @import("klaxon");
const kx = k.kx;
const ui = k.ui;
const sdl = k.sdl;
const w = k.widgets;
const audio = @import("audio.zig");
const runtime = @import("ph_runtime");
const natives = runtime.host_natives;
const Policy = runtime.Policy;

const SLOTS = 64;
const TILE_PX = 52;

const media_source = audio.media_source;
const media_events = audio.media_events;
const media_queue = @import("src/media/queue.zig");
const MediaSource = media_source.MediaSource;

const TrackCtx = struct { g: *G, index: usize, slot: *ui.Node };

const G = struct {
    host: k.Host = undefined,
    io: std.Io = undefined,
    alloc: std.mem.Allocator = undefined,
    // peintures
    p_bg: *kx.Paint = undefined,
    p_card: *kx.Paint = undefined,
    p_card_alt: *kx.Paint = undefined,
    p_sel: *kx.Paint = undefined,
    p_transport: *kx.Paint = undefined,
    p_accent: *kx.Paint = undefined,
    p_accent_press: *kx.Paint = undefined,
    p_track_s: *kx.Paint = undefined,
    p_knob: *kx.Paint = undefined,
    p_focus: *kx.Paint = undefined,
    p_div: *kx.Paint = undefined,
    // paras
    title_para: *kx.Para = undefined,   // now-playing titre
    sub_para: *kx.Para = undefined,     // now-playing sous-titre (état/temps)
    btn_paras: [3]*kx.Para = undefined, // ⏮ ⏯ ⏭
    status_para: *kx.Para = undefined,
    // transport
    btn_prev: w.Button = .{},
    btn_play: w.Button = .{},
    btn_next: w.Button = .{},
    seek: w.Slider = .{},
    vol: w.Slider = .{},
    // arbre
    root: ui.Node = .{},
    header: ui.Node = .{},
    transport: ui.Node = .{},
    divider_node: ui.Node = .{},
    statusbar: ui.Node = .{},
    time_node: ui.Node = .{},
    time_para: *kx.Para = undefined,
    // lazy list pistes
    list: ui.LazyList = undefined,
    slots: [SLOTS]ui.Node = undefined,
    ptrs: [SLOTS + 1]*ui.Node = undefined,
    slot_para: [SLOTS]?*kx.Para = @splat(null),
    slot_kids: [SLOTS][2]ui.Node = undefined,
    slot_kid_ptrs: [SLOTS][2]*ui.Node = undefined,
    slot_label: [SLOTS][160]u8 = undefined,
    tile_ctx: [SLOTS]TrackCtx = undefined,
    // données
    queue: media_queue.Queue = .{},
    scan_json: ?[]u8 = null,        // buffer des titres (propriétaire)
    scanning: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_inited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_err: ?[]const u8 = null,
    music_dir: []const u8 = "music-test",
    plugin_path_arg: ?[]const u8 = null, // --plugin explicite ; sinon résolu vs exe
    autoplay: bool = false,
    // lecture
    engine: audio.Engine = .{},
    selected: ?usize = null,
    // divers
    focus: ui.Focus = .{},
    sem_dirty: bool = true,
    running: bool = true,
    frames: i64 = 0,
    max_frames: i64 = -1,
    deadline_ms: i64 = -1,
    dirty_extra: bool = true,
    last_ms: i64 = 0,
    // status texte courant affiché (rebuild para seulement si muté)
    status_text: [128]u8 = undefined,
    status_len: usize = 0,
    np_text: [256]u8 = undefined,   // now playing label courant
    np_len: usize = 0,
    tm_text: [64]u8 = undefined,
    tm_len: usize = 0,
};

var g: G = .{};
var sem_arena_buf: [256 * 1024]u8 = undefined;

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(g.io, .awake).raw.nanoseconds, 1_000_000));
}

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

fn mkPaint(rgba: u32) *kx.Paint {
    const p = kx.kx_paint_new().?;
    kx.kx_paint_color(p, rgba);
    return p;
}
fn mkPara() *kx.Para {
    return kx.kx_para_new(g.host.ctx, g.host.fonts).?;
}
fn paraOf(p: *kx.Para, size: f32, rgba: u32, text: []const u8, wpx: f32) void {
    _ = kx.kx_para_reset(p);
    _ = kx.kx_para_push_style(p, size, rgba, 400, 0);
    _ = kx.kx_para_add_text_n(p, text.ptr, text.len);
    _ = kx.kx_para_max_lines(p, 1);
    _ = kx.kx_para_layout(p, wpx);
}

fn fmtTime(buf: []u8, us: media_events.Micros) []const u8 {
    const s: u64 = us / 1_000_000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "0:00";
}

// ---------------------------------------------------------------------------
// Scan via le plugin sandboxé (thread — le WAMR call peut durer).
// ---------------------------------------------------------------------------
fn scanWorker() void {
    g.scanning.store(true, .release);
    defer g.scan_done.store(true, .release);
    defer g.scanning.store(false, .release);
    natives.setup(g.alloc, g.io);
    runtime.init() catch {
        g.scan_err = "runtime init failed";
        return;
    };
    // Résolution du scanner : --plugin > <exe>/../../pluginhost/out/ (indép. du cwd)
    var pbuf: [4096]u8 = undefined;
    var plugin_path: []const u8 = g.plugin_path_arg orelse "../pluginhost/out/scanner.wasm";
    if (g.plugin_path_arg == null) {
        var ebuf: [4096]u8 = undefined;
        if (std.Io.Dir.readLinkAbsolute(g.io, "/proc/self/exe", &ebuf)) |n| {
            const exe_dir = std.fs.path.dirname(ebuf[0..n]) orelse ".";
            const p = std.fmt.bufPrint(&pbuf, "{s}/../../pluginhost/out/scanner.wasm", .{exe_dir}) catch "";
            if (p.len > 0) plugin_path = p;
        } else |_| {}
    }
    const is_abs = plugin_path.len > 0 and plugin_path[0] == '/';
    const bytes = (if (is_abs)
        std.Io.Dir.openFileAbsolute(g.io, plugin_path, .{}) catch null
    else
        std.Io.Dir.cwd().openFile(g.io, plugin_path, .{}) catch null) orelse {
        g.scan_err = "scanner.wasm introuvable";
        return;
    };
    const fstat = bytes.stat(g.io) catch { g.scan_err = "stat"; return; };
    const fdata = g.alloc.alloc(u8, @intCast(fstat.size)) catch {
        g.scan_err = "oom";
        return;
    };
    const nread = bytes.readStreaming(g.io, &.{fdata}) catch { g.scan_err = "read"; return; };
    bytes.close(g.io);
    if (nread != fdata.len) { g.scan_err = "short read"; return; }
    const bytes2 = fdata;
    defer g.alloc.free(bytes2);
    var m = runtime.Module.load(bytes2) catch {
        g.scan_err = "wasm load failed";
        return;
    };
    defer m.unload();
    g.scan_inited.store(true, .release); // runtime+natives actifs → teardown côté shutdown
    var grants: std.ArrayList(u8) = .empty;
    defer grants.deinit(g.alloc);
    grants.print(g.alloc, "{{\"permissions\":[\"scan:{s}\"]}}", .{g.music_dir}) catch {
        g.scan_err = "oom";
        return;
    };
    var pol = Policy.parse(g.alloc, grants.items) catch {
        g.scan_err = "policy parse";
        return;
    };
    defer pol.deinit(g.alloc);
    const req = std.fmt.allocPrint(g.alloc, "{{\"op\":\"scan\",\"dir\":\"{s}\"}}", .{g.music_dir}) catch return;
    defer g.alloc.free(req);
    const out = m.call(g.alloc, req, .{ .policy = &pol }) catch |e| {
        g.scan_err = @errorName(e);
        return;
    };
    parseTracks(out);
}

/// {"tracks":[{"title":"..","path":"..","size":N},...]} — extraction minimale,
/// même approche que le plugin (substr JSON; le format est notre contrat).
fn parseTracks(json: []u8) void {
    g.scan_json = json; // les slices pointent dedans — garder vivant
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, json, i, "\"path\":\"")) |p0| {
        const ps = p0 + 8;
        const pe = std.mem.indexOfPos(u8, json, ps, "\"") orelse break;
        const path = json[ps..pe];
        // title avant path dans l'objet : {"title":"..","path":..}
        const tmark = std.mem.lastIndexOf(u8, json[0..ps], "\"title\":\"") orelse break;
        const ts = tmark + 9;
        const te = std.mem.indexOfPos(u8, json, ts, "\"") orelse break;
        const src: MediaSource = .{ .local_file = .{
            .path = path,
            .expected_format = media_source.formatForPath(path),
        } };
        g.queue.items.append(g.alloc, .{ .source = src, .title = json[ts..te] }) catch break;
        i = pe + 1;
    }
    if (g.queue.len() == 0 and g.scan_err == null)
        g.scan_err = "aucune piste trouvée";
}

// ---------------------------------------------------------------------------
// Lecture
// ---------------------------------------------------------------------------
fn playIndex(idx: usize) void {
    const it = g.queue.jump(idx) orelse return;
    g.engine.load(g.alloc, it.source) catch {
        g.scan_err = "decode alloc";
        return;
    };
    g.sem_dirty = true;
    g.dirty_extra = true;
}

fn playItem(_: usize, item: *const media_queue.Item) void {
    g.engine.load(g.alloc, item.source) catch {
        g.scan_err = "decode alloc";
        return;
    };
    g.sem_dirty = true;
    g.dirty_extra = true;
}

fn nextTrack() void {
    if (g.queue.len() == 0) return;
    const cur = g.queue.index orelse 0;
    // fin de file : park (pas de boucle sur la dernière)
    const it = g.queue.next() orelse return;
    playItem(cur + 1, it);
}
fn prevTrack() void {
    if (g.queue.len() == 0) return;
    const it = g.queue.prev() orelse {
        // début de file : rejoue la première
        if (g.queue.current()) |c| playItem(0, c);
        return;
    };
    playItem(0, it);
}
fn togglePlay() void {
    switch (g.engine.state) {
        .playing => g.engine.command(.pause),
        .paused => g.engine.command(.play),
        .idle, .ended, .failed => {
            if (g.queue.len() > 0) playIndex(g.selected orelse 0);
        },
        .loading => {},
    }
    g.dirty_extra = true;
}

// ---------------------------------------------------------------------------
// Widgets callbacks
// ---------------------------------------------------------------------------
fn onPrev(ctx: ?*anyopaque) void { _ = ctx; prevTrack(); }
fn onNext(ctx: ?*anyopaque) void { _ = ctx; nextTrack(); }
fn onPlayBtn(ctx: ?*anyopaque) void { _ = ctx; togglePlay(); }

fn onSeek(v: f32, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    if (gg.engine.total_frames == 0) return;
    gg.engine.command(.{ .seek = @intFromFloat(@as(f64, v) * @as(f64, @floatFromInt(gg.engine.durationUs()))) });
}

fn onVol(v: f32, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    gg.engine.setGain(v);
}

/// subscribe() : le moteur pousse les événements — sur err on le montre,
/// sur tout event on demande un frame (états déjà reflétés dans l'UI).
fn onMediaEvent(_: ?*anyopaque, ev: media_events.MediaEvent) void {
    switch (ev) {
        .err => |e| g.scan_err = e.msg,
        else => {},
    }
    g.dirty_extra = true;
}

fn tileTap(n: *ui.Node, ev: ui.PointerEvent) void {
    const tc: *TrackCtx = @ptrCast(@alignCast(n.userdata orelse return));
    if (ev.kind != .up) return;
    const gg = tc.g;
    gg.selected = tc.index;
    gg.list.invalidate();
    gg.sem_dirty = true;
    gg.dirty_extra = true;
    playIndex(tc.index); // V0 : tap = lecture immédiate
}

fn buildTile(slot: *ui.Node, index: usize, ctx: ?*anyopaque) void {
    const gg: *G = @ptrCast(@alignCast(ctx.?));
    const si = (@intFromPtr(slot) - @intFromPtr(&gg.slots[0])) / @sizeOf(ui.Node);
    const t = gg.queue.items.items[index];
    const lbl = std.fmt.bufPrint(&gg.slot_label[si], "{s}", .{t.title}) catch "?";
    if (gg.slot_para[si] == null) gg.slot_para[si] = mkPara();
    paraOf(gg.slot_para[si].?, 15, ui.theme.text, lbl, 2000);
    gg.slot_kids[si][0] = .{ .size = .{ .px = 16 } };
    gg.slot_kids[si][1] = .{ .paint = .{ .text = gg.slot_para[si] }, .semantics = .{ .role = .text, .label = lbl } };
    gg.slot_kid_ptrs[si][0] = &gg.slot_kids[si][0];
    gg.slot_kid_ptrs[si][1] = &gg.slot_kids[si][1];
    slot.axis = .row;
    slot.gap = 0;
    slot.children = &gg.slot_kid_ptrs[si];
    if (gg.queue.index == index) {
        slot.paint.fill = gg.p_sel;
        slot.selected = true;
    } else {
        slot.paint.fill = if (index % 2 == 1) gg.p_card_alt else gg.p_card;
        slot.selected = false;
    }
    gg.tile_ctx[si] = .{ .g = gg, .index = index, .slot = slot };
    slot.userdata = &gg.tile_ctx[si];
    slot.on_pointer = tileTap;
    slot.semantics = .{ .role = .list_item, .label = lbl };
    gg.sem_dirty = true;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
fn onEvent(e: k.Event) void {
    switch (e) {
        .pointer_down => |p| {
            const ev = ui.PointerEvent{ .kind = .down, .x = p.x, .y = p.y, .button = p.button };
            _ = ui.dispatchScrollable(&g.root, ev);
            const hit = ui.dispatch(&g.root, ev);
            if (hit) |h| g.focus.set(if (h.semantics.focusable) h else null) else g.focus.set(null);
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
            const ev = ui.PointerEvent{ .kind = .wheel, .x = p.x, .y = p.y, .dy = -p.dy * TILE_PX };
            _ = ui.dispatchScrollable(&g.root, ev);
            g.dirty_extra = true;
        },
        .key_down => |ke| {
            switch (ke.key) {
                sdl.SDLK_SPACE => togglePlay(),
                sdl.SDLK_RIGHT => g.engine.command(.{ .seek = g.engine.positionUs() + 5_000_000 }),
                sdl.SDLK_LEFT => g.engine.command(.{ .seek = g.engine.positionUs() -| 5_000_000 }),
                sdl.SDLK_DOWN => {
                    if (g.queue.len() > 0) {
                        g.selected = @min((g.selected orelse 0) + 1, g.queue.len() - 1);
                        g.list.invalidate();
                    }
                },
                sdl.SDLK_UP => {
                    if (g.queue.len() > 0) {
                        const c = g.selected orelse 0;
                        g.selected = if (c == 0) 0 else c - 1;
                        g.list.invalidate();
                    }
                },
                sdl.SDLK_RETURN => if (g.selected) |s| playIndex(s),
                sdl.SDLK_TAB => {
                    var fba_buf: [8 * 1024]u8 = undefined;
                    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
                    const dir: i32 = if ((ke.mod & sdl.KMOD_SHIFT) != 0) -1 else 1;
                    _ = g.focus.move(&g.root, dir, fba.allocator());
                },
                else => if (g.focus.current) |c| {
                    if (c.on_key) |f| _ = f(c, ke.key, ke.mod);
                },
            }
            g.dirty_extra = true;
        },
        .resized => g.dirty_extra = true,
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Labels mutables — rebuild para seulement si le texte a changé.
// ---------------------------------------------------------------------------
fn updateLabel(text: []const u8, buf: []u8, len: *usize, para: *kx.Para,
               size: f32, color: u32, wpx: f32) void {
    if (text.len == len.* and std.mem.eql(u8, buf[0..len.*], text)) return;
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    len.* = n;
    paraOf(para, size, color, buf[0..n], wpx);
    g.dirty_extra = true;
}

fn draw(h: *k.Host) void {
    const t = h.target;
    _ = kx.kx_canvas_clear(t, ui.theme.bg);
    var pw: c_int = 0;
    var ph: c_int = 0;
    kx.kx_target_size(t, &pw, &ph);
    ui.layout(&g.root, .{ .x = 0, .y = 0, .w = @floatFromInt(pw), .h = @floatFromInt(ph) });
    _ = g.list.syncWindow();
    g.list.relayout();
    g.root.draw(t);
    h.presentTarget();
}

fn tick() void {
    if (g.deadline_ms > 0 and nowMs() >= g.deadline_ms) {
        g.running = false;
        return;
    }
    if (!g.host.pollEvents(onEvent)) {
        g.running = false;
        return;
    }

    // scan terminé → remplir la liste
    if (g.scan_done.load(.acquire) and g.queue.len() > 0 and g.list.count == 0) {
        g.list.count = g.queue.len();
        g.list.initNode();
        g.list.invalidate();
        g.dirty_extra = true;
        g.sem_dirty = true;
        if (g.autoplay) playIndex(0);
    }

    // audio : arm stream quand le decode est prêt, puis alimente la file
    if (g.engine.state == .loading) {
        if (g.engine.decode_failed.load(.acquire)) {
            g.engine.close();
            g.scan_err = "decode failed (format ?)";
            g.queue.index = null;
            g.list.invalidate();
        } else _ = g.engine.armIfReady();
    }
    g.engine.feed();
    // fin de piste → enchaîne ; en fin de file le moteur reste .ended (park).
    if (g.engine.state == .ended and (g.queue.index orelse 0) + 1 < g.queue.len())
        nextTrack();

    // transport : seek slider suit la position (sauf drag utilisateur)
    if (!g.seek.dragging and g.engine.durationUs() > 0) {
        const v: f32 = @floatCast(@as(f64, @floatFromInt(g.engine.positionUs())) / @as(f64, @floatFromInt(g.engine.durationUs())));
        if (@abs(v - g.seek.value) > 0.002) { g.seek.value = v; g.dirty_extra = true; }
    }
    // labels : now-playing + temps + status
    {
        var tb: [256]u8 = undefined;
        const np = if (g.queue.current()) |it|
            std.fmt.bufPrint(&tb, "{s} — {s}", .{
                it.title,
                @tagName(g.engine.state) }) catch ""
        else if (g.engine.state == .loading) "decoding…" else "Vehicoule";
        updateLabel(np, &g.np_text, &g.np_len, g.title_para, 18, ui.theme.text, 2000);
    }
    {
        var tb: [64]u8 = undefined;
        var tb2: [24]u8 = undefined;
        const tm = std.fmt.bufPrint(&tb, "{s} / {s}", .{
            fmtTime(&tb2, g.engine.positionUs()),
            fmtTime(tb[32..64], g.engine.durationUs()),
        }) catch "";
        updateLabel(tm, &g.tm_text, &g.tm_len, g.time_para, 13, ui.theme.text_muted, 400);
    }
    {
        var tb: [128]u8 = undefined;
        const st = if (g.scan_err) |e|
            std.fmt.bufPrint(&tb, "scan: {s}", .{e}) catch ""
        else if (g.scanning.load(.acquire))
            std.fmt.bufPrint(&tb, "scan {s}…", .{g.music_dir}) catch ""
        else
            std.fmt.bufPrint(&tb, "{d} pistes — {s} · {d}o en file", .{
                g.queue.len(), g.music_dir, g.engine.queuedBytes() });
        updateLabel(st catch "", &g.status_text, &g.status_len, g.status_para, 12, ui.theme.text_muted, 1200);
    }
    // bouton play : libellé ▶/⏸ selon l'état — rebuild si muté
    {
        const lbl: []const u8 = if (g.engine.state == .playing) "II" else ">";
        paraOf(g.btn_paras[1], 18, 0xFFFFFFFF, lbl, 60);
    }

    if (g.dirty_extra) { g.host.dirty = true; g.dirty_extra = false; }
    // lecture en cours → frames continues (seek suit + feed)
    if (g.engine.state == .playing or g.engine.state == .loading or
        g.scanning.load(.acquire)) g.host.dirty = true;
    if (g.sem_dirty) {
        g.sem_dirty = false;
        var fba = std.heap.FixedBufferAllocator.init(&sem_arena_buf);
        g.host.syncA11y(&g.root, fba.allocator()) catch {};
    }
    if (g.max_frames > 0 and g.frames < g.max_frames) g.host.dirty = true;
    switch (g.host.step(draw, null, 4)) {
        .drew => {
            g.frames += 1;
            if (g.max_frames > 0 and g.frames >= g.max_frames) g.running = false;
        },
        .quit => g.running = false,
        .idle => {},
    }
}

fn a11yPress(ctx: ?*anyopaque, node: *ui.Node, action: c_int) void {
    _ = ctx;
    if (action == 1 or action == 2) {
        g.focus.set(node);
        const key: u32 = if (action == 1) sdl.SDLK_RIGHT else sdl.SDLK_LEFT;
        onEvent(.{ .key_down = .{ .key = key, .mod = 0 } });
        return;
    }
    const b = node.bounds;
    onEvent(.{ .pointer_down = .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2, .button = 1 } });
    onEvent(.{ .pointer_up = .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2, .button = 1 } });
}

fn setup(font_data: []const u8) !void {
    g.host = try k.Host.initGlWindow(g.io, "Vehicoule", 900, 640);
    _ = kx.kx_fonts_add(g.host.fonts, font_data.ptr, @intCast(font_data.len));

    g.p_bg = mkPaint(ui.theme.bg);
    g.p_card = mkPaint(ui.theme.surface);
    g.p_card_alt = mkPaint(ui.theme.surface2);
    g.p_sel = mkPaint(mix(ui.theme.accent, ui.theme.text, 0.25));
    g.p_transport = mkPaint(ui.theme.surface);
    g.p_accent = mkPaint(ui.theme.accent);
    g.p_accent_press = mkPaint(mix(ui.theme.accent, 0x000000FF, 0.15));
    g.p_track_s = mkPaint(ui.theme.surface2);
    g.p_knob = mkPaint(ui.theme.text);
    g.p_focus = mkPaint(ui.theme.accent);
    g.p_div = mkPaint(ui.theme.border);

    g.title_para = mkPara();
    g.sub_para = mkPara();
    g.time_para = mkPara();
    g.status_para = mkPara();
    for (&g.btn_paras) |*p| p.* = mkPara();
    paraOf(g.btn_paras[0], 15, 0xFFFFFFFF, "|<", 60);
    paraOf(g.btn_paras[1], 18, 0xFFFFFFFF, ">", 60);
    paraOf(g.btn_paras[2], 15, 0xFFFFFFFF, ">|", 60);

    g.btn_prev = .{ .on_tap = onPrev, .ctx = &g, .normal = g.p_accent, .active = g.p_accent_press };
    g.btn_prev.node.size = .{ .px = 44 };
    g.btn_prev.node.cross = 40;
    g.btn_prev.node.paint.text = g.btn_paras[0];
    g.btn_prev.node.paint.text_align = .center;
    g.btn_prev.node.semantics.label = "Précédent";
    g.btn_prev.node.paint.focus_ring = g.p_focus;
    g.btn_prev.bind();

    g.btn_play = .{ .on_tap = onPlayBtn, .ctx = &g, .normal = g.p_accent, .active = g.p_accent_press };
    g.btn_play.node.size = .{ .px = 52 };
    g.btn_play.node.cross = 40;
    g.btn_play.node.paint.text = g.btn_paras[1];
    g.btn_play.node.paint.text_align = .center;
    g.btn_play.node.semantics.label = "Lecture/Pause";
    g.btn_play.node.paint.focus_ring = g.p_focus;
    g.btn_play.bind();

    g.btn_next = .{ .on_tap = onNext, .ctx = &g, .normal = g.p_accent, .active = g.p_accent_press };
    g.btn_next.node.size = .{ .px = 44 };
    g.btn_next.node.cross = 40;
    g.btn_next.node.paint.text = g.btn_paras[2];
    g.btn_next.node.paint.text_align = .center;
    g.btn_next.node.semantics.label = "Suivant";
    g.btn_next.node.paint.focus_ring = g.p_focus;
    g.btn_next.bind();

    g.seek = .{ .value = 0, .on_change = onSeek, .ctx = &g, .track = g.p_track_s, .fill = g.p_accent, .knob = g.p_knob };
    g.seek.node.size = .{ .weight = 1 };
    g.seek.node.cross = 32;
    g.seek.node.semantics.label = "Position";
    g.seek.node.paint.focus_ring = g.p_focus;
    g.seek.bind();

    g.vol = .{ .value = 1.0, .on_change = onVol, .ctx = &g, .track = g.p_track_s, .fill = g.p_accent, .knob = g.p_knob };
    g.vol.node.size = .{ .px = 90 };
    g.vol.node.cross = 32;
    g.vol.node.semantics.label = "Volume";
    g.vol.node.paint.focus_ring = g.p_focus;
    g.vol.bind();

    g.time_node = .{ .size = .{ .px = 84 }, .cross = 32, .pad = 6, .paint = .{ .text = g.time_para } };

    // liste des pistes
    g.list = .{ .count = 0, .item_extent = TILE_PX, .builder = buildTile,
                .ctx = &g, .slots = &g.slots, .slot_ptrs = &g.ptrs };
    g.list.initNode();
    g.list.host_node.semantics = .{ .role = .list, .label = "Pistes" };
    _ = g.list.syncWindow();

    g.header = .{ .size = .{ .px = 64 }, .pad = 16, .paint = .{ .text = g.title_para },
                  .semantics = .{ .role = .header, .label = "Lecture en cours" } };
    g.transport = .{ .size = .{ .px = 52 }, .axis = .row, .pad = 8, .gap = 10,
                     .paint = .{ .fill = g.p_transport },
                     .children = &.{ &g.btn_prev.node, &g.btn_play.node,
                                    &g.btn_next.node, &g.seek.node,
                                    &g.time_node, &g.vol.node } };
    g.divider_node = .{ .size = .{ .px = 1 }, .paint = .{ .fill = g.p_div } };
    g.statusbar = .{ .size = .{ .px = 26 }, .pad = 10,
                     .paint = .{ .text = g.status_para, .fill = g.p_transport } };
    g.root = .{ .axis = .column,
                .children = &.{ &g.header, &g.transport, &g.divider_node,
                               &g.list.host_node, &g.statusbar } };
    g.host.setA11yActionHandler(a11yPress, &g);
    // le bouton play est l'action principale → label AT
    g.root.semantics = .{ .label = "Vehicoule" };
}

fn runApp(init: std.process.Init) !void {
    g.io = init.io;
    g.alloc = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            if (args.next()) |n| g.max_frames = std.fmt.parseInt(i64, n, 10) catch -1;
        } else if (std.mem.eql(u8, a, "--secs")) {
            if (args.next()) |n| g.deadline_ms = nowMs() + (std.fmt.parseInt(i64, n, 10) catch 0) * 1000;
        } else if (std.mem.eql(u8, a, "--dir")) {
            if (args.next()) |d| g.music_dir = d;
        } else if (std.mem.eql(u8, a, "--plugin")) {
            if (args.next()) |p| g.plugin_path_arg = p;
        } else if (std.mem.eql(u8, a, "--autoplay")) {
            g.autoplay = true;
        } else if (std.mem.eql(u8, a, "--theme")) {
            if (args.next()) |tn| {
                if (std.mem.eql(u8, tn, "light")) ui.theme = .light;
            }
        }
    }
    const font_data = try std.Io.Dir.cwd().readFileAlloc(g.io,
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", init.gpa, .limited(8 << 20));
    defer init.gpa.free(font_data);
    try setup(font_data);
    g.engine.subscribe(.{ .ctx = null, .cb = onMediaEvent });

    // scan via le plugin en thread (ne bloque pas le premier frame)
    if (std.c.getenv("KXP_SYNC_SCAN") != null) {
        scanWorker();
    } else {
        const th = std.Thread.spawn(.{}, scanWorker, .{}) catch null;
        if (th) |t| t.detach();
    }

    while (g.running) tick();

    var sbuf: [640]u8 = undefined;
    const line = std.fmt.bufPrint(&sbuf,
        "{{\"tool\":\"vehicoule-v0\",\"backend\":\"{s}\",\"driver\":\"{s}\",\"frames\":{},\"avg_ms\":{d:.3},\"p99_ms\":{d:.3},\"first_frame_ms\":{d:.3},\"tracks\":{},\"state\":\"{s}\",\"pos\":{d:.1},\"fed\":{},\"queued\":{}}}\n",
        .{ @tagName(g.host.backend()), g.host.driverInfo(),
           g.host.stats.frames, g.host.stats.avgFrameMs(), g.host.stats.p99FrameMs(),
           g.host.stats.first_frame_ms, g.queue.len(),
           @tagName(g.engine.state), @as(f64, @floatFromInt(g.engine.positionUs())) / 1e6,
           g.engine.fed_frames, g.engine.queuedBytes() }) catch "";
    std.debug.print("{s}", .{line});
    g.engine.close();
    if (g.scan_json) |sj| g.alloc.free(sj);
    g.queue.deinit(g.alloc);
    // teardown runtime wasm après la fin du scan (unload déjà fait dans le worker)
    while (g.scanning.load(.acquire)) {
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    if (g.scan_inited.load(.acquire)) {
        natives.reset();
        runtime.deinit();
    }
    g.host.deinit();
}

pub fn main(init: std.process.Init) !void {
    return runApp(init);
}
