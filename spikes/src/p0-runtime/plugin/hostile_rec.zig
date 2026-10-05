// hostile_rec.zig — récursion infinie (stack overflow wasm) + table démesurée
const std = @import("std");

var buf: [16]u8 = undefined;

fn rec(n: u64) u64 {
    return rec(n + 1) +% 1;   // récursion non-terminale → déborde la pile wasm
}

// (la table démesurée est générée à la main, voir make_hostiles.py)

export fn vh_alloc(len: u32) u32 {
    _ = len;
    return @intFromPtr(&buf);
}
export fn vh_free(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len;
}
export fn vh_call(ptr: u32, len: u32) u64 {
    _ = ptr;
    _ = len;
    _ = rec(0);
    return 0;
}
