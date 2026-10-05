// toy.zig — plugin jouet ABI Vehicoule 0.1 (ADR-0007)
// exports vh_alloc / vh_free / vh_call ; "search" sur fixture JSON embarquée.
// Build : zig build-lib -target wasm32-freestanding -O ReleaseSmall -fno-entry -rdynamic
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

export fn vh_alloc(len: u32) u32 {
    const buf = arena.allocator().alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn vh_free(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len; // arena : libération par reset global dans vh_call
}

// Imports hôte (module vh_host)
extern "vh_host" fn request(ptr: u32, len: u32) i32;
extern "vh_host" fn read(handle: i32, ptr: u32, cap: u32) i32;
extern "vh_host" fn release(handle: i32) i32;

const fixture =
    \\{"items":[
    \\  {"title":"Subterranean Homesick Blues","artist":"Dylan","id":"t1"},
    \\  {"title":"Klaxon Siren March","artist":"Test Band","id":"t2"},
    \\  {"title":"quiet evening","artist":"lofi ken","id":"t3"},
    \\  {"title":"Submarine","artist":"Yellow","id":"t4"}
    \\]}
;

fn containsCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= hay.len) : (i += 1) {
        for (needle, 0..) |nc, j| {
            const hc = std.ascii.toLower(hay[i + j]);
            if (hc != std.ascii.toLower(nc)) continue :outer;
        }
        return true;
    }
    return false;
}

// vh_call reçoit {"op":"search","args":{"q":"..."}} (JSON, sans parseur complet :
// extraction naïve du champ "q" suffit pour le jouet).
fn extractQuery(req: []const u8) []const u8 {
    const key = "\"q\":\"";
    const idx = std.mem.indexOf(u8, req, key) orelse return "";
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, req, start, '"') orelse return "";
    return req[start..end];
}

export fn vh_call(ptr: u32, len: u32) u64 {
    defer _ = arena.reset(.retain_capacity);
    const req = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    const a = arena.allocator();

    var out = std.ArrayList(u8).initCapacity(a, 256) catch trap_();
    const q = extractQuery(req);
    out.appendSlice(a, "{\"ok\":{\"hits\":[") catch trap_();
    var first = true;
    var it = std.mem.splitScalar(u8, fixture, '\n');
    while (it.next()) |line| {
        if (!containsCase(line, q)) continue;
        if (!first) out.append(a, ',') catch trap_();
        first = false;
        out.appendSlice(a, std.mem.trim(u8, line, " ")) catch trap_();
    }
    out.appendSlice(a, "]}}") catch trap_();

    // Exemple d'appel hôte : si args.hostcall=true, on demande un handle.
    if (std.mem.indexOf(u8, req, "hostcall") != null) {
        const hc = "ping";
        const h = request(vh_alloc(hc.len), hc.len);
        _ = h;
    }

    const buf = a.alloc(u8, out.items.len) catch trap_();
    @memcpy(buf, out.items);
    return (@as(u64, @intCast(buf.len)) << 32) | @as(u32, @intFromPtr(buf.ptr));
}

fn trap_() noreturn {
    unreachable;
}

// Exports pour les modules hostiles (build séparé par section)
export fn spin() void {
    while (true) {}
}
