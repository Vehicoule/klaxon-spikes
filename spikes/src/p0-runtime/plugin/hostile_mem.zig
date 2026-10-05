// hostile_mem.zig — memory.grow agressif + sortie 100 Mio
const std = @import("std");
export fn vh_alloc(len: u32) u32 {
    // réserve jusqu'à 256 Mio — doit être refusé par le budget (≤64 Mio)
    var grown: usize = 0;
    while (grown < 4096) : (grown += 1) {  // pages wasm 64Kio → 4096 pages = 256 Mio
        const old = @wasmMemoryGrow(0, 1);
        if (old == std.math.maxInt(usize)) break;  // -1 (échec) vu en usize
    }
    var dummy: [16]u8 = undefined;
    _ = len;
    return @intFromPtr(&dummy);
}
export fn vh_free(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len;
}
export fn vh_call(ptr: u32, len: u32) u64 {
    // prétend renvoyer 100 Mio (len<<32 | ptr) avec ptr dans le vide — le runtime
    // doit borner la sortie (sorties bornées, ADR-0007).
    _ = ptr;
    _ = len;
    return (@as(u64, 100 * 1024 * 1024) << 32) | 64;
}
