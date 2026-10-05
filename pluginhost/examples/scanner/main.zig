// scanner — plugin officiel "fichiers locaux" (justifie la capacité scan:).
// op=scan : reçoit {"op":"scan","dir":"<path>"} → demande à l'hôte
// "scan:<dir>" via vh_host.request → lit le JSONL {"path","size"} →
// renvoie {"tracks":[{"title","path","size"},...]}.
const std = @import("std");
const vh = @import("vh");

comptime { _ = vh; }

fn extractStr(req: []const u8, key: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, req, key) orelse return "";
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, req, start, '"') orelse return "";
    return req[start..end];
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn stem(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}

fn jsonField(line: []const u8, key: []const u8) []const u8 {
    // extrait la valeur string d'un "key":"..." dans une ligne JSONL
    var kbuf: [32]u8 = undefined;
    const k = std.fmt.bufPrint(&kbuf, "\"{s}\":\"", .{key}) catch return "";
    const idx = std.mem.indexOf(u8, line, k) orelse return "";
    const start = idx + k.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return "";
    return line[start..end];
}

pub fn vhHandler(input: []const u8, a: std.mem.Allocator) ![]u8 {
    const dir = extractStr(input, "\"dir\":\"");
    if (dir.len == 0)
        return std.fmt.allocPrint(a, "{{\"error\":\"missing dir\"}}", .{});

    const req = try std.fmt.allocPrint(a, "scan:{s}", .{dir});
    const h = try vh.hostRequest(req);
    defer vh.hostRelease(h);
    const listing = try vh.hostReadAll(h, a, vh.MAX_PAYLOAD);

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"tracks\":[");
    var first = true;
    var it = std.mem.splitScalar(u8, listing, '\n');
    while (it.next()) |line| {
        if (line.len < 4) continue;
        const path = jsonField(line, "path");
        if (path.len == 0) continue;
        const size = jsonField(line, "size");
        if (!first) try out.appendSlice(a, ",");
        first = false;
        try out.print(a, "{{\"title\":\"{s}\",\"path\":\"{s}\",\"size\":{s}}}", .{
            stem(basename(path)), path, size,
        });
    }
    try out.appendSlice(a, "]}");
    return out.toOwnedSlice(a);
}
