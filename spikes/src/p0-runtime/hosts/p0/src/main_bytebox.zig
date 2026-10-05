// main_bytebox.zig — harnais P0 bytebox (metering activé à la compile)
// Mesure : instanciation, appel, budgets fuel/mémoire, hostiles.
const std = @import("std");
const bytebox = @import("bytebox");

const FUEL_INTERACTIVE: usize = 200_000_000;
const FUEL_LONG: usize = 2_000_000_000;

var next_handle: i32 = 1;

fn hostRequest(userdata: ?*anyopaque, module: *bytebox.ModuleInstance, params: [*]const bytebox.Val, returns: [*]bytebox.Val) error{}!void {
    _ = userdata;
    _ = module;
    _ = params;
    const h = next_handle;
    next_handle += 1;
    returns[0] = .{ .I32 = h };
}

fn hostRead(userdata: ?*anyopaque, module: *bytebox.ModuleInstance, params: [*]const bytebox.Val, returns: [*]bytebox.Val) error{}!void {
    _ = userdata;
    _ = module;
    _ = params;
    returns[0] = .{ .I32 = 0 };
}

fn hostRelease(userdata: ?*anyopaque, module: *bytebox.ModuleInstance, params: [*]const bytebox.Val, returns: [*]bytebox.Val) error{}!void {
    _ = userdata;
    _ = module;
    _ = params;
    returns[0] = .{ .I32 = 0 };
}

const Case = struct {
    name: []const u8,
    path: []const u8,
    fuel: usize,
    mem_max_pages: usize,   // 0 = pas de limite mesurée
    table_ok: bool = true,
    expect: enum { ok, trap, load_fail },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    const dir = if (args.len > 1) args[1] else "../../plugin/wasm";
    const only: ?[]const u8 = if (args.len > 2) args[2] else null;

    const cases = [_]Case{
        .{ .name = "toy", .path = "toy.wasm", .fuel = FUEL_INTERACTIVE, .mem_max_pages = 0, .expect = .ok },
        .{ .name = "loop", .path = "hostiles.wasm", .fuel = 5_000_000, .mem_max_pages = 0, .expect = .trap },
        .{ .name = "mem", .path = "hostile_mem.wasm", .fuel = FUEL_INTERACTIVE, .mem_max_pages = 0, .expect = .ok },
        .{ .name = "recursion", .path = "hostile_rec.wasm", .fuel = 50_000, .mem_max_pages = 0, .expect = .trap },
        .{ .name = "table1M", .path = "hostile_table.wasm", .fuel = FUEL_INTERACTIVE, .mem_max_pages = 0, .expect = .load_fail },
        .{ .name = "edge64", .path = "edge_mem64.wasm", .fuel = FUEL_INTERACTIVE, .mem_max_pages = 0, .expect = .ok },
    };

    const out_file = std.fs.File.stdout();
    const emit = struct {
        fn print(f: std.fs.File, aa: std.mem.Allocator, comptime fmt: []const u8, a2: anytype) !void {
            const s = try std.fmt.allocPrint(aa, fmt, a2);
            defer aa.free(s);
            try f.writeAll(s);
        }
    }.print;
    try emit(out_file, a, "{s}", .{"{"});

    var first_out = true;
    for (cases, 0..) |c, ci| {
        _ = ci;
        if (only) |o| if (!std.mem.eql(u8, c.name, o)) continue;
        if (!first_out) try emit(out_file, a, ",", .{});
        first_out = false;
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, c.path });
        const bytes = std.fs.cwd().readFileAlloc(a, path, 64 * 1024 * 1024) catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"error\":\"read:{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };
        defer a.free(bytes);

        var t0 = std.time.nanoTimestamp();

        var def = bytebox.createModuleDefinition(a, .{}) catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"error\":\"def:{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };
        defer def.destroy();
        def.decode(bytes) catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"load_fail\",\"reason\":\"{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };

        var inst = bytebox.createModuleInstance(.Stack, def, a) catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"error\":\"inst:{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };
        defer inst.destroy();

        var imports = try bytebox.ModuleImportPackage.init("vh_host", null, null, a);
        defer imports.deinit();
        try imports.addHostFunction("request", &[_]bytebox.ValType{ .I32, .I32 }, &[_]bytebox.ValType{.I32}, hostRequest, null);
        try imports.addHostFunction("read", &[_]bytebox.ValType{ .I32, .I32, .I32 }, &[_]bytebox.ValType{.I32}, hostRead, null);
        try imports.addHostFunction("release", &[_]bytebox.ValType{.I32}, &[_]bytebox.ValType{.I32}, hostRelease, null);

        inst.instantiate(.{ .imports = &[_]bytebox.ModuleImportPackage{imports} }) catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"instantiate_fail\",\"reason\":\"{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };
        const inst_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;

        const handle = inst.getFunctionHandle("vh_call") catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"noexport\",\"reason\":\"{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };

        // appel préalable vh_alloc(1024) pour exercer memory.grow
        var alloc_ms: f64 = 0;
        if (inst.getFunctionHandle("vh_alloc")) |ah| {
            var ap = [_]bytebox.Val{.{ .I32 = 1024 }};
            var ar = [_]bytebox.Val{.{ .I32 = 0 }};
            const at0 = std.time.nanoTimestamp();
            inst.invoke(ah, &ap, &ar, .{ .meter = c.fuel }) catch |e| {
                alloc_ms = -1;
                try emit(out_file, a, "\"{s}\":{{\"status\":\"alloc_trap\",\"trap\":\"{s}\"}}", .{ c.name, @errorName(e) });
                continue;
            };
            alloc_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - at0)) / 1e6;
        } else |_| {}

        // invoque vh_call(0,0) avec fuel
        var params = [_]bytebox.Val{ .{ .I32 = 0 }, .{ .I32 = 0 } };
        var rets = [_]bytebox.Val{.{ .I64 = 0 }};
        t0 = std.time.nanoTimestamp();
        const r = inst.invoke(handle, &params, &rets, .{ .meter = c.fuel });
        const call_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;

        if (r) |_| {
            const v: u64 = @bitCast(rets[0].I64);
            const plen: u32 = @intCast(v >> 32);
            const pptr: u32 = @truncate(v);
            const mem = inst.memoryAll();
            const bounded: usize = @min(plen, 256);
            var oklen = false;
            var preview: []const u8 = "";
            if (plen <= mem.len and pptr < mem.len and pptr + plen <= mem.len) {
                oklen = true;
                preview = mem[pptr .. pptr + bounded];
            }
            try emit(out_file, a, "\"{s}\":{{\"status\":\"ok\",\"inst_ms\":{d:.2},\"call_ms\":{d:.2},\"ret_len\":{d},\"ret_valid\":{},\"ret\":\"{s}\",\"mem_bytes\":{d},\"alloc_ms\":{d:.2}}}", .{
                c.name, inst_ms, call_ms, plen, oklen, preview, mem.len, alloc_ms,
            });
        } else |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"trap\",\"trap\":\"{s}\",\"inst_ms\":{d:.2},\"call_ms\":{d:.2}}}", .{
                c.name, @errorName(e), inst_ms, call_ms,
            });
        }
    }
    try emit(out_file, a, "}}\n", .{});
}
