// natives.zig — implémentation hôte de vh_host.{request,read,release}.
//
// État global + mutex : le contrat ABI v0.1 est single-flight (un appel vh_call
// en vol à la fois, cf sdk/vh.zig) — donc un registre de handles global est
// suffisant pour l'instant. Quand le contrat passera multi-flight, il faudra
// passer à un contexte par instance (WAMR permet un attachment par native).
const std = @import("std");
const wamr = @import("wamr.zig");
const policy_mod = @import("policy.zig");
const Policy = policy_mod.Policy;

pub const Err = struct {
    pub const perm: i32 = -1; // refusé par la policy
    pub const badreq: i32 = -2; // requête malformée/inconnue
    pub const io: i32 = -3; // échec FS
    pub const nosys: i32 = -4; // transport pas implémenté
    pub const badh: i32 = -5; // handle inconnu
    pub const toobig: i32 = -6; // réponse > cap transport
};

const Pending = struct {
    buf: []u8, // contenu produit par la requête, lu par chunks
    pos: usize = 0,
    owner: *wamr.WasmModuleInst, // isolation : un handle n'appartient qu'à
    // l'instance qui l'a créé — read/release d'un autre plugin → badh.
};

var g_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var g_alloc: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_pending: std.AutoHashMap(i32, Pending) = undefined;
var g_next_handle: i32 = 1;
var g_ready = false;

/// À appeler une fois : bind alloc + io.
/// La policy n'est PAS globale : chaque instance porte la sienne dans son
/// custom_data (InstData) — plusieurs plugins avec des grants différents
/// peuvent coexister sans swap. Le mutex ne sert plus qu'à g_pending.
pub fn setup(a: std.mem.Allocator, io: std.Io) void {
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);
    if (g_ready) return;
    g_alloc = a;
    g_io = io;
    g_pending = std.AutoHashMap(i32, Pending).init(a);
    g_ready = true;
}

/// Attachement par instance : la policy du plugin.
pub const InstData = struct {
    policy: ?*const Policy = null,
};

pub fn instDataOf(inst: *wamr.WasmModuleInst) ?*InstData {
    return @ptrCast(@alignCast(wamr.wasm_runtime_get_custom_data(inst)));
}

/// Crée l'attachement si absent, retourne l'InstData (null hors-setup/oom).
pub fn ensureInstData(inst: *wamr.WasmModuleInst) ?*InstData {
    if (instDataOf(inst)) |d| return d;
    if (!g_ready) return null;
    const d = g_alloc.create(InstData) catch return null;
    d.* = .{};
    wamr.wasm_runtime_set_custom_data(inst, d);
    return d;
}

/// À appeler AVANT deinstantiate : libère l'attachement + purge les
/// réponses pending de cette instance (sinon elles fuient jusqu'à reset).
pub fn detach(inst: *wamr.WasmModuleInst) void {
    if (!g_ready) return;
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);
    var stale: std.ArrayList(i32) = .empty;
    defer stale.deinit(g_alloc);
    var it = g_pending.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.owner == inst) stale.append(g_alloc, e.key_ptr.*) catch break;
    }
    for (stale.items) |h| {
        const e = g_pending.fetchRemove(h).?;
        g_alloc.free(e.value.buf);
    }
    if (instDataOf(inst)) |d| g_alloc.destroy(d);
    wamr.wasm_runtime_set_custom_data(inst, null);
}

pub fn reset() void {
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);
    if (!g_ready) return;
    var it = g_pending.iterator();
    while (it.next()) |e| g_alloc.free(e.value_ptr.buf);
    g_pending.deinit();
    g_ready = false;
}

fn instOf(env: ?*wamr.WasmExecEnv) ?*wamr.WasmModuleInst {
    return wamr.wasm_runtime_get_module_inst(env orelse return null);
}

fn appSlice(env: ?*wamr.WasmExecEnv, ptr: u32, len: u32) ?[]const u8 {
    const inst = instOf(env) orelse return null;
    if (!wamr.wasm_runtime_validate_app_addr(inst, ptr, len)) return null;
    const np = wamr.wasm_runtime_addr_app_to_native(inst, ptr) orelse return null;
    return @as([*]const u8, @ptrCast(np))[0..len];
}

/// vh_host.request(ptr,len) -> i32 : payload texte "scheme:arg".
///   "scan:<dir>"    → JSONL {"path","size"} des fichiers média du dossier
///   "fs:read:<path>"→ contenu du fichier (cap MAX_PAYLOAD)
///   "http(s):<url>" → GET bornée (MAX_HTTP), domaine gate par policy,
///                     redirects non suivies (unhandled — un hop cross-domaine
///                     contournerait le allowlist). Non-2xx → Err.io.
fn hostRequest(env: ?*wamr.WasmExecEnv, ptr: u32, len: u32) callconv(.c) i32 {
    const req = appSlice(env, ptr, len) orelse return Err.badreq;
    const inst = instOf(env) orelse return Err.badreq;
    // Policy de CETTE instance — lue hors mutex (champ stable, même thread).
    const pol = if (instDataOf(inst)) |d| d.policy orelse &EMPTY_POLICY
        else &EMPTY_POLICY;
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);

    var buf: []u8 = undefined;
    if (std.mem.startsWith(u8, req, "scan:")) {
        const dir = req["scan:".len..];
        if (!pol.allows(.scan, dir)) return Err.perm;
        buf = buildScan(g_io, g_alloc, dir) catch return Err.io;
    } else if (std.mem.startsWith(u8, req, "fs:read:")) {
        const path = req["fs:read:".len..];
        if (!pol.allows(.fs_read, path)) return Err.perm;
        buf = std.Io.Dir.cwd().readFileAlloc(g_io, path, g_alloc,
            .limited(8 << 20)) catch return Err.io;
    } else if (std.mem.startsWith(u8, req, "http:") or
        std.mem.startsWith(u8, req, "https:"))
    {
        const host = hostOf(req);
        if (!pol.allows(.network, host)) return Err.perm;
        buf = httpGet(req) catch |e| switch (e) {
            error.OverCap => return Err.toobig, // réponse > cap → refusée
            else => return Err.io,
        };
    } else return Err.badreq;

    const h = g_next_handle;
    g_next_handle += 1;
    g_pending.put(h, .{ .buf = buf, .owner = inst }) catch {
        g_alloc.free(buf);
        return Err.io;
    };
    return h;
}

/// vh_host.read(handle, ptr, cap) -> i32 : copie ≤cap octets du pending.
/// Retourne le nombre d'octets copiés (0 = fin de flux).
fn hostRead(env: ?*wamr.WasmExecEnv, h: i32, ptr: u32, cap: u32) callconv(.c) i32 {
    const inst = instOf(env) orelse return Err.badreq;
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);
    const e = g_pending.getPtr(h) orelse return Err.badh;
    if (e.owner != inst) return Err.badh; // handle étranger → inconnu
    const avail = e.buf.len - e.pos;
    const n: u32 = @intCast(@min(avail, cap));
    if (n == 0) return 0;
    if (!wamr.wasm_runtime_validate_app_addr(inst, ptr, n)) return Err.badreq;
    const np = wamr.wasm_runtime_addr_app_to_native(inst, ptr) orelse return Err.badreq;
    const dst = @as([*]u8, @ptrCast(np))[0..n];
    @memcpy(dst, e.buf[e.pos .. e.pos + n]);
    e.pos += n;
    return @intCast(n);
}

/// vh_host.release(handle) -> i32
fn hostRelease(env: ?*wamr.WasmExecEnv, h: i32) callconv(.c) i32 {
    const inst = instOf(env) orelse return Err.badreq;
    _ = std.c.pthread_mutex_lock(&g_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_mutex);
    const e = g_pending.getPtr(h) orelse return Err.badh;
    if (e.owner != inst) return Err.badh;
    const buf = e.buf; // e vit dans la map — invalide après remove()
    _ = g_pending.remove(h);
    g_alloc.free(buf);
    return 0;
}

const EMPTY_POLICY = Policy{};

// --- Transport HTTP : GET bornée, policy sur le domaine --------------------
// std.http.Client.fetch + sink custom à cap fixe (pas d'Allocating :
// un serveur hostile ne doit pas pouvoir gonfler la mémoire hôte).
pub const MAX_HTTP: usize = 16 << 20; // cap réponse http (v0.1)

const BoundedSink = struct {
    w: std.Io.Writer,
    list: std.ArrayList(u8),
    a: std.mem.Allocator,
    cap: usize,
    over: bool = false,

    fn init(a: std.mem.Allocator, cap: usize) BoundedSink {
        return .{
            .w = .{ .buffer = &.{}, .vtable = &vtable },
            .list = .empty,
            .a = a,
            .cap = cap,
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *BoundedSink = @fieldParentPtr("w", w);
        const count = std.Io.Writer.countSplat(data, splat);
        if (s.list.items.len + count > s.cap) {
            s.over = true;
            return error.WriteFailed; // remonte FetchError.WriteFailed
        }
        for (data[0 .. data.len - 1]) |d| s.list.appendSlice(s.a, d) catch return error.WriteFailed;
        const last = data[data.len - 1];
        for (0..splat) |_| s.list.appendSlice(s.a, last) catch return error.WriteFailed;
        return count;
    }
};

/// GET synchronisée : le mutex g_mutex est déjà tenu par hostRequest —
/// acceptable en v0.1 single-flight (un appel en vol au total).
fn httpGet(url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = g_alloc, .io = g_io };
    defer client.deinit();
    var sink = BoundedSink.init(g_alloc, MAX_HTTP);
    defer sink.list.deinit(g_alloc);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &sink.w,
        .redirect_behavior = .unhandled, // un hop cross-domaine = bypass policy
    }) catch {
        if (sink.over) return error.OverCap;
        return error.HttpFailed;
    };
    if (@intFromEnum(res.status) / 100 != 2) return error.HttpStatus;
    return sink.list.toOwnedSlice(g_alloc);
}

fn hostOf(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.indexOfAny(u8, s, "/?#")) |i| s = s[0..i];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i]; // port
    return s;
}

const MEDIA_EXTS = [_][]const u8{ ".mp3", ".flac", ".ogg", ".oga", ".opus", ".m4a", ".wav", ".aac", ".wma" };

const SCAN_MAX_DEPTH = 8; // bibliothèque = artiste/album/piste — borne anti-cycle

fn buildScan(io: std.Io, a: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try scanDir(io, a, dir_path, 0, &out);
    return out.toOwnedSlice(a);
}

fn scanDir(io: std.Io, a: std.mem.Allocator, dir_path: []const u8,
           depth: u8, out: *std.ArrayList(u8)) !void {
    if (depth >= SCAN_MAX_DEPTH) return;
    const is_abs = dir_path.len > 0 and dir_path[0] == '/';
    var dir = (if (is_abs) std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true })
              else std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) catch
        return; // dossier illisible : on saute la branche, pas tout le scan
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind == .directory) {
            const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
            defer a.free(sub);
            try scanDir(io, a, sub, depth + 1, out);
            continue;
        }
        if (ent.kind != .file) continue;
        const lower = std.ascii.allocLowerString(a, ent.name) catch continue;
        defer a.free(lower);
        var media = false;
        for (MEDIA_EXTS) |ext| {
            if (std.mem.endsWith(u8, lower, ext)) {
                media = true;
                break;
            }
        }
        if (!media) continue;
        const st = dir.statFile(io, ent.name, .{}) catch continue;
        try out.print(a, "{{\"path\":\"{s}/{s}\",\"size\":{d}}}\n", .{
            dir_path, ent.name, st.size,
        });
    }
}

// Table d'enregistrement — signatures WAMR "(args)ret" avec i=i32.
// request(env,ptr,len): "(ii)i" ; read(env,h,ptr,cap): "(iii)i" ; release(env,h): "(i)i"
// VAR et non const : register_natives trie le tableau in-place (rodata → segv).
pub var natives = [_]wamr.NativeSymbol{
    .{ .name = "request", .func = @ptrCast(&hostRequest), .signature = "(ii)i" },
    .{ .name = "read", .func = @ptrCast(&hostRead), .signature = "(iii)i" },
    .{ .name = "release", .func = @ptrCast(&hostRelease), .signature = "(i)i" },
};

// --- Tests ------------------------------------------------------------------
// httpGet est pur Zig (pas d'extern wamr) → testable sans libwamr.
// Hors-ligne : le test saute en notant (verdict réseau = dépendant de l'env).

test "httpGet : GET bornée retourne du contenu (http réel si dispo)" {
    g_alloc = std.testing.allocator;
    g_io = std.Io.Threaded.global_single_threaded.io();
    const body = httpGet("http://example.com/") catch |e| {
        std.debug.print("httpGet skipped ({s})\n", .{@errorName(e)});
        return;
    };
    defer g_alloc.free(body);
    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "Example") != null);
}

test "httpGet : OverCap quand la réponse dépasse le cap" {
    g_alloc = std.testing.allocator;
    g_io = std.Io.Threaded.global_single_threaded.io();
    // cap minuscule forcé via BoundedSink directement
    var sink = BoundedSink.init(std.testing.allocator, 4);
    defer sink.list.deinit(std.testing.allocator);
    try std.testing.expectError(error.WriteFailed, sink.w.writeAll("abcdefghij"));
    try std.testing.expect(sink.over);
}
