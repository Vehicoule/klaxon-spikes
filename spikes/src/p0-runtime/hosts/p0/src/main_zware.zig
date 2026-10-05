// main_zware.zig — harnais P0 zware (pas de metering dans zware : mesuré tel quel)
const std = @import("std");
const zware = @import("zware");

var next_handle: i32 = 1;

fn hostRequest(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
    _ = ctx;
    _ = vm.popOperand(u64);   // ptr
    _ = vm.popOperand(u64);   // len
    const h = next_handle;
    next_handle += 1;
    try vm.pushOperand(u64, @intCast(@as(u32, @bitCast(h))));
}

fn hostRead(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
    _ = ctx;
    _ = vm.popOperand(u64);
    _ = vm.popOperand(u64);
    _ = vm.popOperand(u64);
    try vm.pushOperand(u64, 0);
}

fn hostRelease(vm: *zware.VirtualMachine, ctx: usize) zware.WasmError!void {
    _ = ctx;
    _ = vm.popOperand(u64);
    try vm.pushOperand(u64, 0);
}

const Case = struct { name: []const u8, path: []const u8 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    const dir = if (args.len > 1) args[1] else "../../plugin/wasm";
    const only: ?[]const u8 = if (args.len > 2) args[2] else null;

    const cases = [_]Case{
        .{ .name = "toy", .path = "toy.wasm" },
        .{ .name = "loop", .path = "hostiles.wasm" },   // SANS fuel : timeout watchdog externe
        .{ .name = "mem", .path = "hostile_mem.wasm" },
        .{ .name = "recursion", .path = "hostile_rec.wasm" },
        .{ .name = "table1M", .path = "hostile_table.wasm" },
        .{ .name = "edge64", .path = "edge_mem64.wasm" },
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

        var store = zware.Store.init(a);
        defer store.deinit();
        try store.exposeHostFunction("vh_host", "request", hostRequest, 0, &[_]zware.ValType{ .I32, .I32 }, &[_]zware.ValType{.I32});
        try store.exposeHostFunction("vh_host", "read", hostRead, 0, &[_]zware.ValType{ .I32, .I32, .I32 }, &[_]zware.ValType{.I32});
        try store.exposeHostFunction("vh_host", "release", hostRelease, 0, &[_]zware.ValType{.I32}, &[_]zware.ValType{.I32});

        var module = zware.Module.init(a, bytes);
        defer module.deinit();
        module.decode() catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"load_fail\",\"reason\":\"{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };

        var inst = zware.Instance.init(a, &store, module);
        defer inst.deinit();
        inst.instantiate() catch |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"instantiate_fail\",\"reason\":\"{s}\"}}", .{ c.name, @errorName(e) });
            continue;
        };
        const inst_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;

        var in = [_]u64{ 0, 0 };
        var ret = [_]u64{0};
        t0 = std.time.nanoTimestamp();
        const r = inst.invoke("vh_call", &in, &ret, .{});
        const call_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;

        if (r) |_| {
            const v = ret[0];
            const plen: u32 = @intCast(v >> 32);
            const pptr: u32 = @truncate(v);
            var oklen = false;
            var preview_len: usize = 0;
            var mem_bytes: usize = 0;
            if (inst.getMemory(0)) |m| {
                mem_bytes = m.sizeBytes();
                if (plen <= mem_bytes and pptr < mem_bytes and pptr + plen <= mem_bytes) {
                    oklen = true;
                    preview_len = @min(plen, 64);
                }
            } else |_| {}
            var preview: [64]u8 = undefined;
            if (oklen and preview_len > 0) {
                const m = try inst.getMemory(0);
                for (0..preview_len) |i| {
                    preview[i] = try m.read(u8, 0, @intCast(pptr + i));
                }
            }
            try emit(out_file, a, "\"{s}\":{{\"status\":\"ok\",\"inst_ms\":{d:.2},\"call_ms\":{d:.2},\"ret_len\":{d},\"ret_valid\":{},\"ret\":\"{s}\",\"mem_bytes\":{d}}}", .{
                c.name, inst_ms, call_ms, plen, oklen, preview[0..preview_len], mem_bytes,
            });
        } else |e| {
            try emit(out_file, a, "\"{s}\":{{\"status\":\"trap\",\"trap\":\"{s}\",\"inst_ms\":{d:.2},\"call_ms\":{d:.2}}}", .{
                c.name, @errorName(e), inst_ms, call_ms,
            });
        }
    }
    try emit(out_file, a, "}}\n", .{});
}
