// selftest.zig — selftest PluginRuntime (corpus hostile p0-runtime + scanner).
// Usage : pluginhost-test <dir_wasm> [dir_fixture]
//   dir_wasm  : dossier des .wasm (spikes/p0-runtime/plugin/wasm)
//   dir_fixture : dossier scannable (défaut /tmp/klaxon-music-fixture)
// Sortie : une ligne JSON par cas + "RESULT:PASS|FAIL".
const std = @import("std");
const runtime = @import("runtime.zig");
const natives = @import("natives.zig");
const policy_mod = @import("policy.zig");
const Policy = policy_mod.Policy;

var g_a: std.mem.Allocator = undefined;
var g_io: std.Io = undefined;
var g_dir: []const u8 = undefined;
var g_pass = true;

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn emit(name: []const u8, ok: bool, detail: []const u8) void {
    if (!ok) g_pass = false;
    std.debug.print("{{\"case\":\"{s}\",\"ok\":{s},\"detail\":\"{s}\"}}\n", .{
        name, if (ok) "true" else "false", detail,
    });
}

fn readWasm(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}.wasm", .{ g_dir, name });
    defer a.free(path);
    return try std.Io.Dir.cwd().readFileAlloc(g_io, path, a, .limited(64 << 20));
}

fn expectValidate(name: []const u8, want: ?runtime.Error) !void {
    const bytes = try readWasm(g_a, name);
    defer g_a.free(bytes);
    if (want) |w| {
        runtime.validateModule(bytes) catch |e| {
            emit(name, e == w, @errorName(e));
            return;
        };
        emit(name, false, "validate accepted");
    } else {
        runtime.validateModule(bytes) catch |e| {
            emit(name, false, @errorName(e));
            return;
        };
        emit(name, true, "validate ok");
    }
}

fn caseToy(a: std.mem.Allocator) !void {
    const bytes = try readWasm(a, "toy");
    defer a.free(bytes);
    var m = try runtime.Module.load(bytes);
    defer m.unload();
    const out = try m.call(a,
        \\{"op":"search","args":{"q":"sub","hostcall":1}}
    , .{});
    defer a.free(out);
    const ok = std.mem.indexOf(u8, out, "Subterranean") != null;
    emit("toy-search", ok, "hit Subterranean attendu");
}

fn caseFuel(a: std.mem.Allocator) !void {
    const bytes = try readWasm(a, "hostiles");
    defer a.free(bytes);
    var m = try runtime.Module.load(bytes);
    defer m.unload();
    const t0 = nowMs();
    const r = m.call(a, "{}", .{ .fuel = 5_000_000 });
    const ms = nowMs() - t0;
    const ok = if (r) |_| blk: {
        a.free(r catch unreachable);
        break :blk false;
    } else |e| e == runtime.Error.Trapped;
    const d = try std.fmt.allocPrint(a, "fuel trap {d}ms", .{ms});
    defer a.free(d);
    emit("fuel-loop", ok, d);
}

fn caseDeadline(a: std.mem.Allocator) !void {
    const bytes = try readWasm(a, "hostiles");
    defer a.free(bytes);
    var m = try runtime.Module.load(bytes);
    defer m.unload();
    const t0 = nowMs();
    const r = m.call(a, "{}", .{ .fuel = 2_000_000_000, .deadline_ms = 300 });
    const ms = nowMs() - t0;
    const ok = if (r) |o| blk: {
        a.free(o);
        break :blk false;
    } else |e| e == runtime.Error.Terminated;
    const d = try std.fmt.allocPrint(a, "deadline {d}ms (cible ~300)", .{ms});
    defer a.free(d);
    emit("deadline-terminate", ok and ms < 2000, d);
}

fn caseBoundedOut(a: std.mem.Allocator) !void {
    const bytes = try readWasm(a, "hostile_mem");
    defer a.free(bytes);
    var m = try runtime.Module.load(bytes);
    defer m.unload();
    const r = m.call(a, "{}", .{});
    // hostile_mem prétend 100 Mio → OutputTooBig ou InvalidOutput (les deux refusent)
    const ok = if (r) |o| blk: {
        a.free(o);
        break :blk false;
    } else |e| e == runtime.Error.OutputTooBig or e == runtime.Error.InvalidOutput;
    emit("bounded-output", ok, "claim 100Mio refusé");
}

fn caseScanner(a: std.mem.Allocator, fixture_dir: []const u8) !void {
    const bytes = try readWasm(a, "scanner");
    defer a.free(bytes);
    var m = try runtime.Module.load(bytes);
    defer m.unload();

    // 1) sans permission scan: → request refuse → plugin renvoie error
    const req = try std.fmt.allocPrint(a,
        "{{\"op\":\"scan\",\"dir\":\"{s}\"}}", .{fixture_dir});
    defer a.free(req);
    const out0 = try m.call(a, req, .{});
    defer a.free(out0);
    const denied = std.mem.indexOf(u8, out0, "RequestFailed") != null or
        std.mem.indexOf(u8, out0, "error") != null;
    emit("scanner-deny", denied and
        std.mem.indexOf(u8, out0, "flac") == null, "scan refusé sans grant");

    // 2) avec permission scan:<dir> → tracks
    var grants_text: std.ArrayList(u8) = .empty;
    defer grants_text.deinit(a);
    try grants_text.print(a,
        "{{\"permissions\":[\"scan:{s}\"]}}", .{fixture_dir});
    var pol = try Policy.parse(a, grants_text.items);
    defer pol.deinit(a);
    const out1 = try m.call(a, req, .{ .policy = &pol });
    defer a.free(out1);
    const hits = std.mem.indexOf(u8, out1, ".flac") != null and
        std.mem.indexOf(u8, out1, ".mp3") != null;
    emit("scanner-allow", hits, "mp3+flac trouvés");
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    g_a = a;
    g_io = init.io;
    const argv = init.minimal.args.vector; // 0.17 : args via Init
    g_dir = if (argv.len > 1) std.mem.span(argv[1]) else "spikes/p0-runtime/plugin/wasm";
    const fixture = if (argv.len > 2) std.mem.span(argv[2]) else "/tmp/klaxon-music-fixture";

    natives.setup(a, g_io);
    try runtime.init();

    // validation au load
    try expectValidate("toy", null);
    try expectValidate("hostile_table", runtime.Error.TableLimit);
    try expectValidate("edge_mem64", null); // seuil 1024 pages déclaré = accepté
    try expectValidate("hostile_rec", null); // recursion OK au load, trappé à l'appel

    // appels bornés
    try caseToy(a);
    try caseFuel(a);
    try caseDeadline(a);
    try caseBoundedOut(a);

    // recursion hostile : fuel la tue aussi
    {
        const bytes = try readWasm(a, "hostile_rec");
        defer a.free(bytes);
        var m = try runtime.Module.load(bytes);
        defer m.unload();
        const r = m.call(a, "{}", .{ .fuel = 50_000 });
        const ok = if (r) |o| blk: {
            a.free(o);
            break :blk false;
        } else |e| e == runtime.Error.Trapped;
        emit("fuel-recursion", ok, "récursion trappée par fuel");
    }

    try caseScanner(a, fixture);

    std.debug.print("RESULT:{s}\n", .{if (g_pass) "PASS" else "FAIL"});
}
