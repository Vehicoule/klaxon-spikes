// vh.zig — Vehicoule Plugin SDK (ADR-0007, contrat ABI v0.1).
//
// Usage minimal dans le plugin (root) :
//     const vh = @import("vh.zig");
//     comptime { _ = vh; }                  // force l'émission des exports
//     pub const vhHandler = myHandler;
//     fn myHandler(input: []const u8, a: std.mem.Allocator) ![]u8 { ... }
//
// Le handler reçoit la requête en slice (≤ 8 Mio, cap host) et retourne la
// réponse allouée depuis `a` (scratch arena resettée après chaque appel).
// Un handler absent répond {"error":"NoHandler"} — jamais de crash.
//
// Build (obligatoire pour la gate de limites host) :
//   zig build-exe -target wasm32-freestanding -O ReleaseSmall \
//       -fno-entry -rdynamic --max-memory=67108864 plugin.zig
// --max-memory produit la déclaration mem.max≤64Mio que PluginRuntime exige ;
// sans elle memory.grow n'est pas borné (résiduel P0).

const std = @import("std");
const root = @import("root");

/// Cap payload miroir du host ADR-0007.
pub const MAX_PAYLOAD = 8 * 1024 * 1024;

/// Signature du point d'entrée métier du plugin.
pub const Handler = *const fn (input: []const u8, a: std.mem.Allocator) anyerror![]u8;

fn defaultHandler(input: []const u8, a: std.mem.Allocator) ![]u8 {
    _ = input;
    return std.fmt.allocPrint(a, "{{\"error\":\"NoHandler\"}}", .{});
}

const handler: Handler = if (@hasDecl(root, "vhHandler")) root.vhHandler else defaultHandler;

// Imports hôte (module "vh_host", ADR-0007) — le host les enregistre
// comme natives WAMR ; non utilisés par un plugin qui ne fait pas de requête.
extern "vh_host" fn request(ptr: u32, len: u32) i32;
extern "vh_host" fn read(handle: i32, ptr: u32, cap: u32) i32;
extern "vh_host" fn release(handle: i32) i32;

// Scratch arena : toute la mémoire de travail d'un appel y vit ; elle est
// resettée à la fin de vh_call (l'input vh_alloc, la réponse packée, le
// travail interne du plugin). Un seul appel en vol (contrat wasm single-thread).
var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);

export fn vh_alloc(len: u32) u32 {
    if (len == 0) return 0; // le host ignore vh_alloc(0) (validate_app_addr)
    const p = scratch.allocator().alloc(u8, len) catch return 0;
    return @intFromPtr(p.ptr);
}

export fn vh_free(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len; // arena : libéré au reset post-call
}

export fn vh_call(ptr: u32, len: u32) u64 {
    defer _ = scratch.reset(.retain_capacity);
    const a = scratch.allocator();
    const input = if (len == 0)
        @as([]const u8, "")
    else
        @as([*]const u8, @ptrFromInt(ptr))[0..len];
    const out = handler(input, a) catch |e| blk: {
        break :blk std.fmt.allocPrint(a,
            "{{\"error\":\"{s}\"}}", .{@errorName(e)}) catch trap();
    };
    // pack : (len<<32)|ptr — la réponse vit dans l'arena, valide jusqu'au reset
    // (le host la copie avant le prochain appel).
    return (@as(u64, @intCast(out.len)) << 32) | @as(u32, @intFromPtr(out.ptr));
}

fn trap() noreturn {
    unreachable;
}

// ---------------------------------------------------------------------------
// Conveniences hôte (optionnelles)
// ---------------------------------------------------------------------------

pub const HostError = error{ RequestFailed, ReadFailed, TooBig };

/// Envoie `payload` à l'hôte (≤ MAX_PAYLOAD) → handle de réponse à lire.
pub fn hostRequest(payload: []const u8) HostError!i32 {
    if (payload.len > MAX_PAYLOAD) return error.TooBig;
    const h = request(@intFromPtr(payload.ptr), @intCast(payload.len));
    return if (h < 0) error.RequestFailed else h;
}

/// Lit le contenu du handle dans un buffer `alloc` de cap octets max.
pub fn hostReadAll(h: i32, a: std.mem.Allocator, cap: usize) HostError![]u8 {
    const buf = a.alloc(u8, cap) catch return error.ReadFailed;
    const n = read(h, @intFromPtr(buf.ptr), @intCast(buf.len));
    if (n < 0) return error.ReadFailed;
    return buf[0..@intCast(n)];
}

/// Libère le handle côté hôte (à appeler après hostReadAll).
pub fn hostRelease(h: i32) void {
    _ = release(h);
}
