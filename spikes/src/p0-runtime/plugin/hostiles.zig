// hostiles.zig — modules hostiles du corpus P0 (compilés un par un via -Dhostile=)
const std = @import("std");

var buf: [1024]u8 = undefined;

// hostile=loop : boucle infinie dans vh_call (test fuel/deadline)
export fn vh_call(ptr: u32, len: u32) u64 {
    _ = ptr;
    _ = len;
    if (@hasDecl(@This(), "MODE")) unreachable;
    while (true) {}
}

export fn vh_alloc(len: u32) u32 {
    _ = len;
    return @intFromPtr(&buf);
}
export fn vh_free(ptr: u32, len: u32) void {
    _ = ptr;
    _ = len;
}
