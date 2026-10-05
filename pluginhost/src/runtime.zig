// runtime.zig — PluginRuntime Zig/WAMR fast-interp (ADR-0007, ABI v0.1).
//
// Budgets hôte (cf P0-RESULT.md) :
//  1. validation au load — sections wasm lues en Zig AVANT wasm_runtime_load :
//     memory min/max ≤ 64 Mio (1024 pages), table min ≤ 65536, exports
//     vh_alloc + vh_call requis.
//  2. fuel par appel — instruction_count_limit (tue boucle infinie/récursion).
//  3. deadline wall-clock — watchdog thread → wasm_runtime_terminate.
//  4. sortie bornée — validate_app_addr + cap 8 Mio sur la réponse.
//  5. stack 64 Kio, heap 0 (mémoire linéaire guest uniquement).
const std = @import("std");
const wamr = @import("wamr.zig");
const natives = @import("natives.zig");
const policy_mod = @import("policy.zig");
// Ré-exports : un seul module zig par consommateur (player V0).
pub const host_natives = natives;
pub const Policy = policy_mod.Policy;

pub const Error = error{
    InitFailed,
    NativesFailed,
    Malformed,
    MemoryLimit,
    TableLimit,
    MissingExport,
    LoadFailed,
    InstantiateFailed,
    MissingFunction,
    ExecEnvFailed,
    AllocFailed,
    Trapped,
    Terminated,
    OutputTooBig,
    InvalidOutput,
    OutOfMemory,
};

pub const MAX_MEM_PAGES: u64 = 1024; // 64 Mio
pub const MAX_TABLE_ELEMS: u64 = 65536;
pub const MAX_OUTPUT: usize = 8 << 20;
pub const STACK_SIZE: u32 = 64 << 10;
pub const FUEL_INTERACTIVE: i32 = 200_000_000;
pub const FUEL_LONG: i32 = 2_000_000_000;
pub const DEADLINE_MS: u64 = 30_000;

var g_init_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var g_init_state: enum { uninit, ok, failed } = .uninit;

/// Idempotent. Enregistre aussi les natives vh_host.
pub fn init() Error!void {
    _ = std.c.pthread_mutex_lock(&g_init_mutex);
    defer _ = std.c.pthread_mutex_unlock(&g_init_mutex);
    if (g_init_state == .uninit) {
        var args = wamr.RuntimeInitArgs{ .mem_alloc_type = 2 }; // system allocator
        g_init_state = if (wamr.wasm_runtime_full_init(&args) and
            wamr.wasm_runtime_register_natives("vh_host", &natives.natives, natives.natives.len))
            .ok
        else
            .failed;
    }
    if (g_init_state != .ok) return Error.InitFailed;
}

pub fn deinit() void {
    wamr.wasm_runtime_destroy();
}

// ---------------------------------------------------------------------------
// Validation des sections avant load
// ---------------------------------------------------------------------------

const SectionLimits = struct {
    mem_min: u64 = 0,
    mem_max: u64 = 0,
    table_min: u64 = 0,
    has_vh_alloc: bool = false,
    has_vh_call: bool = false,
};

fn leb(b: []const u8, i: *usize) !u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (i.* >= b.len) return error.Malformed;
        const byte = b[i.*];
        i.* += 1;
        v |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return v;
        if (shift >= 63) return error.Malformed;
        shift += 7;
    }
}

fn limitsFlags(b: []const u8, i: *usize, end: usize) !struct { min: u64, max: u64, has_max: bool } {
    const flags = try leb(b, i);
    if (flags > 0x0F) return error.Malformed;
    const min = try leb(b, i);
    var max: u64 = 0;
    // bit0 = has max ; bits1-3 = shared/mem64/page-size (le max reste bit0)
    const has_max = (flags & 1) != 0;
    if (has_max) max = try leb(b, i);
    _ = end;
    return .{ .min = min, .max = max, .has_max = has_max };
}

/// Parcourt les sections qui nous intéressent : 4=table, 5=memory, 7=export.
pub fn validateModule(b: []const u8) Error!void {
    if (b.len < 8 or !std.mem.eql(u8, b[0..4], "\x00asm")) return Error.Malformed;
    var lim = SectionLimits{};
    var i: usize = 8;
    while (i < b.len) {
        const id = b[i];
        i += 1;
        const sz = leb(b, &i) catch return Error.Malformed;
        const end = i + @as(usize, @intCast(sz));
        if (end > b.len) return Error.Malformed;
        const sec = b[i..end];
        switch (id) {
            4 => try scanTable(sec, &lim),
            5 => try scanMemory(sec, &lim),
            7 => try scanExports(sec, &lim),
            else => {},
        }
        i = end;
    }
    if (lim.mem_min > MAX_MEM_PAGES) return Error.MemoryLimit;
    if (lim.mem_max > MAX_MEM_PAGES) return Error.MemoryLimit;
    if (lim.table_min > MAX_TABLE_ELEMS) return Error.TableLimit;
    if (!lim.has_vh_alloc or !lim.has_vh_call) return Error.MissingExport;
}

fn scanMemory(sec: []const u8, lim: *SectionLimits) Error!void {
    var i: usize = 0;
    const n = leb(sec, &i) catch return Error.Malformed;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const l = limitsFlags(sec, &i, sec.len) catch return Error.Malformed;
        lim.mem_min = @max(lim.mem_min, l.min);
        if (l.has_max) lim.mem_max = @max(lim.mem_max, l.max) else lim.mem_max = MAX_MEM_PAGES + 1;
    }
}

fn scanTable(sec: []const u8, lim: *SectionLimits) Error!void {
    var i: usize = 0;
    const n = leb(sec, &i) catch return Error.Malformed;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        if (i >= sec.len) return Error.Malformed;
        _ = sec[i]; // reftype (0x70 funcref / 0x6F externref)
        i += 1;
        // certains modules encodent flags d'abord (table64) : on suit
        // l'encodage standard reftype puis limits.
        const l = limitsFlags(sec, &i, sec.len) catch return Error.Malformed;
        lim.table_min = @max(lim.table_min, l.min);
    }
}

fn scanExports(sec: []const u8, lim: *SectionLimits) Error!void {
    var i: usize = 0;
    const n = leb(sec, &i) catch return Error.Malformed;
    var k: u64 = 0;
    while (k < n) : (k += 1) {
        const nl = leb(sec, &i) catch return Error.Malformed;
        const e = i + @as(usize, @intCast(nl));
        if (e > sec.len) return Error.Malformed;
        const name = sec[i..e];
        i = e;
        if (i >= sec.len) return Error.Malformed;
        i += 1; // kind
        _ = leb(sec, &i) catch return Error.Malformed; // index
        if (std.mem.eql(u8, name, "vh_alloc")) lim.has_vh_alloc = true;
        if (std.mem.eql(u8, name, "vh_call")) lim.has_vh_call = true;
    }
}

// ---------------------------------------------------------------------------
// Module chargé + instancié
// ---------------------------------------------------------------------------

pub const CallOpts = struct {
    fuel: i32 = FUEL_INTERACTIVE,
    deadline_ms: u64 = DEADLINE_MS,
    policy: ?*const Policy = null,
};

const Watchdog = struct {
    inst: *wamr.WasmModuleInst,
    deadline_ms: u64,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(w: *Watchdog) void {
        // ticks de 10ms pour ne pas dépasser la deadline de plus d'un tick.
        const ticks = @max(1, w.deadline_ms / 10);
        var t: u64 = 0;
        while (t < ticks) : (t += 1) {
            if (w.done.load(.acquire)) return;
            var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 10_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        if (!w.done.load(.acquire)) wamr.wasm_runtime_terminate(w.inst);
    }
};

pub const Module = struct {
    mod: *wamr.WasmModule,
    inst: *wamr.WasmModuleInst,
    env: *wamr.WasmExecEnv,
    fn_alloc: *wamr.WasmFunction,
    fn_call: *wamr.WasmFunction,
    terminated: bool = false,

    /// Valide les bornes déclarées, charge et instancie (stack 64Kio, heap 0).
    pub fn load(bytes: []const u8) Error!Module {
        try init();
        try validateModule(bytes);
        var err: [256]u8 = undefined;
        const mod = wamr.wasm_runtime_load(
            bytes.ptr, @intCast(bytes.len), &err, err.len,
        ) orelse return Error.LoadFailed;
        errdefer wamr.wasm_runtime_unload(mod);
        const inst = wamr.wasm_runtime_instantiate(
            mod, STACK_SIZE, 0, &err, err.len,
        ) orelse return Error.InstantiateFailed;
        errdefer wamr.wasm_runtime_deinstantiate(inst);
        const fa = wamr.wasm_runtime_lookup_function(inst, "vh_alloc") orelse
            return Error.MissingFunction;
        const fc = wamr.wasm_runtime_lookup_function(inst, "vh_call") orelse
            return Error.MissingFunction;
        const env = wamr.wasm_runtime_create_exec_env(inst, STACK_SIZE) orelse
            return Error.ExecEnvFailed;
        return .{ .mod = mod, .inst = inst, .env = env, .fn_alloc = fa, .fn_call = fc };
    }

    pub fn unload(m: *Module) void {
        natives.detach(m.inst); // libère l'InstData avant l'instance
        wamr.wasm_runtime_destroy_exec_env(m.env);
        wamr.wasm_runtime_deinstantiate(m.inst);
        wamr.wasm_runtime_unload(m.mod);
        m.* = undefined;
    }

    fn exception(m: *const Module) ?[]const u8 {
        const e = wamr.wasm_runtime_get_exception(m.inst) orelse return null;
        return std.mem.span(e);
    }

    /// appel vh_alloc/vh_call interne — pose le fuel puis invoque.
    /// Distingue Terminated (watchdog → "terminated by user") des autres traps.
    fn rawCall(m: *Module, func: *wamr.WasmFunction, argv: []u32, fuel: i32) Error!void {
        _ = wamr.wasm_runtime_set_instruction_count_limit(m.env, fuel);
        if (wamr.wasm_runtime_call_wasm(m.env, func, @intCast(argv.len), argv.ptr)) return;
        if (m.exception()) |e| {
            if (std.mem.indexOf(u8, e, "terminat") != null) return Error.Terminated;
        }
        return Error.Trapped;
    }

    /// Appel complet : vh_alloc(len) → copie input → vh_call(ptr,len) →
    /// relecture bornée de la réponse (validate_app_addr + cap 8 Mio).
    /// La slice retournée appartient à `a` (caller la libère).
    pub fn call(m: *Module, a: std.mem.Allocator, input: []const u8, opts: CallOpts) Error![]u8 {
        if (m.terminated) return Error.Terminated;
        if (input.len > MAX_OUTPUT) return Error.OutputTooBig;
        // Policy portée par l'instance (multi-flight : pas de swap global).
        if (natives.ensureInstData(m.inst)) |d| d.policy = opts.policy;
        defer if (natives.instDataOf(m.inst)) |d| {
            d.policy = null;
        };

        // watchdog deadline (spawned même pour fuel court : coût ~un thread)
        var wd = Watchdog{ .inst = m.inst, .deadline_ms = opts.deadline_ms };
        const th = std.Thread.spawn(.{}, Watchdog.run, .{&wd}) catch null;
        defer {
            wd.done.store(true, .release);
            if (th) |t| t.join();
        }

        var argv = [2]u32{ @intCast(input.len), 0 };
        m.rawCall(m.fn_alloc, argv[0..1], opts.fuel) catch |e| {
            m.terminated = (e == Error.Terminated);
            return e;
        };
        const gptr = argv[0];
        if (gptr == 0) return Error.AllocFailed;
        if (!wamr.wasm_runtime_validate_app_addr(m.inst, gptr, @intCast(input.len)))
            return Error.InvalidOutput;
        const np = wamr.wasm_runtime_addr_app_to_native(m.inst, gptr) orelse
            return Error.InvalidOutput;
        @memcpy(@as([*]u8, @ptrCast(np))[0..input.len], input);

        argv = .{ gptr, @intCast(input.len) };
        m.rawCall(m.fn_call, argv[0..2], opts.fuel) catch |e| {
            m.terminated = (e == Error.Terminated);
            return e;
        };
        const pptr = argv[0];
        const plen = argv[1];
        if (plen > MAX_OUTPUT) return Error.OutputTooBig;
        if (!wamr.wasm_runtime_validate_app_addr(m.inst, pptr, plen))
            return Error.InvalidOutput;
        const op = wamr.wasm_runtime_addr_app_to_native(m.inst, pptr) orelse
            return Error.InvalidOutput;
        const out = a.alloc(u8, plen) catch return Error.OutOfMemory;
        @memcpy(out, @as([*]const u8, @ptrCast(op))[0..plen]);
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests — couverture du gate de validation LEB (zig test, sans libwamr :
// seuls les chemins non-externs sont émis).
// ---------------------------------------------------------------------------

fn putU7(b: *std.ArrayList(u8), a: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (true) {
        var byte: u8 = @intCast(x & 0x7F);
        x >>= 7;
        if (x != 0) byte |= 0x80;
        try b.append(a, byte);
        if (x == 0) return;
    }
}

fn emitSec(b: *std.ArrayList(u8), a: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try b.append(a, id);
    try putU7(b, a, payload.len);
    try b.appendSlice(a, payload);
}

fn memSec(a: std.mem.Allocator, min: u64, max: ?u64) ![]u8 {
    var p: std.ArrayList(u8) = .empty;
    try putU7(&p, a, 1); // 1 entry
    try putU7(&p, a, if (max == null) 0 else 1); // flags
    try putU7(&p, a, min);
    if (max) |m| try putU7(&p, a, m);
    return p.toOwnedSlice(a);
}

fn tableSec(a: std.mem.Allocator, min: u64) ![]u8 {
    var p: std.ArrayList(u8) = .empty;
    try putU7(&p, a, 1); // 1 entry
    try p.append(a, 0x70); // funcref
    try putU7(&p, a, 0); // flags : pas de max
    try putU7(&p, a, min);
    return p.toOwnedSlice(a);
}

fn exportSec(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var p: std.ArrayList(u8) = .empty;
    try putU7(&p, a, names.len);
    for (names) |n| {
        try putU7(&p, a, n.len);
        try p.appendSlice(a, n);
        try p.append(a, 0); // kind = func
        try putU7(&p, a, 0); // index
    }
    return p.toOwnedSlice(a);
}

/// Assemble un module wasm minimal : magic+version + sections données.
fn mkWasm(a: std.mem.Allocator, secs: []const []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "\x00asm\x01\x00\x00\x00");
    for (secs) |s| try b.appendSlice(a, s);
    return b.toOwnedSlice(a);
}

test "validateModule : module valide accepté (boundary mémoire 1024 incluse)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u64{ 1, 32, 1024 }) |pages| {
        const s = try secWrap(a, 5, try memSec(a, pages, pages));
        const e = try secWrap(a, 7, try exportSec(a, &.{ "vh_alloc", "vh_call" }));
        const m = try mkWasm(a, &.{ s, e });
        try validateModule(m);
    }
}

fn secWrap(a: std.mem.Allocator, id: u8, payload: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try emitSec(&b, a, id, payload);
    return b.toOwnedSlice(a);
}

test "validateModule : pas de max déclaré → rejeté (unbounded)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try secWrap(a, 5, try memSec(a, 16, null));
    const e = try secWrap(a, 7, try exportSec(a, &.{ "vh_alloc", "vh_call" }));
    const m = try mkWasm(a, &.{ s, e });
    try std.testing.expectError(Error.MemoryLimit, validateModule(m));
}

test "validateModule : min ou max > 1024 pages → MemoryLimit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{ .{ 1025, 1025 }, .{ 16, 2048 } }) |mm| {
        const s = try secWrap(a, 5, try memSec(a, mm[0], mm[1]));
        const e = try secWrap(a, 7, try exportSec(a, &.{ "vh_alloc", "vh_call" }));
        const m = try mkWasm(a, &.{ s, e });
        try std.testing.expectError(Error.MemoryLimit, validateModule(m));
    }
}

test "validateModule : table min > 65536 → TableLimit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try secWrap(a, 4, try tableSec(a, 70000));
    const s = try secWrap(a, 5, try memSec(a, 8, 8));
    const e = try secWrap(a, 7, try exportSec(a, &.{ "vh_alloc", "vh_call" }));
    const m = try mkWasm(a, &.{ t, s, e });
    try std.testing.expectError(Error.TableLimit, validateModule(m));
}

test "validateModule : exports manquants → MissingExport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try secWrap(a, 5, try memSec(a, 8, 8));
    inline for (.{ &.{ "vh_alloc" }, &.{"vh_call"}, &.{} }) |names| {
        const e = try secWrap(a, 7, try exportSec(a, names));
        const m = try mkWasm(a, &.{ s, e });
        try std.testing.expectError(Error.MissingExport, validateModule(m));
    }
}

test "validateModule : malformed — magic, taille tronquée, LEB débordant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Error.Malformed, validateModule("\x00asm"));
    try std.testing.expectError(Error.Malformed, validateModule("nope____"));
    var trunc: std.ArrayList(u8) = .empty;
    try trunc.appendSlice(a, "\x00asm\x01\x00\x00\x00");
    try trunc.append(a, 5);
    try putU7(&trunc, a, 9999); // section taille > fin du buffer
    try std.testing.expectError(Error.Malformed, validateModule(trunc.items));
    // flags > 0x0F dans une memory section
    var bad: std.ArrayList(u8) = .empty;
    try putU7(&bad, a, 1);
    try putU7(&bad, a, 0x40); // flags invalides
    try putU7(&bad, a, 1);
    const s = try secWrap(a, 5, bad.items);
    const e = try secWrap(a, 7, try exportSec(a, &.{ "vh_alloc", "vh_call" }));
    const m = try mkWasm(a, &.{ s, e });
    try std.testing.expectError(Error.Malformed, validateModule(m));
}

// (le scanner réel et les hostiles du corpus sont couverts par selftest.zig —
// ici on couvre la logique LEB pure : boundary, rejet unbounded, malformed)
