// Plugin exemple : recherche naïve sur une fixture embarquée, via le SDK.
// Démontre : pub const vhHandler (zéro boilerplate ABI) + hostRequest optionnel.
const std = @import("std");
const vh = @import("vh");

comptime { _ = vh; } // force l'émission des exports vh_alloc/vh_free/vh_call

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

fn extractQuery(req: []const u8) []const u8 {
    const key = "\"q\":\"";
    const idx = std.mem.indexOf(u8, req, key) orelse return "";
    const start = idx + key.len;
    const end = std.mem.indexOfScalarPos(u8, req, start, '"') orelse return "";
    return req[start..end];
}

pub const vhHandler = handle;

fn handle(req: []const u8, a: std.mem.Allocator) ![]u8 {
    const q = extractQuery(req);
    var out = std.ArrayList(u8).initCapacity(a, 256) catch return error.Oom;
    try out.appendSlice(a, "{\"ok\":{\"hits\":[");
    var first = true;
    var it = std.mem.splitScalar(u8, fixture, '\n');
    while (it.next()) |line| {
        if (!containsCase(line, q)) continue;
        if (!first) try out.append(a, ',');
        first = false;
        try out.appendSlice(a, std.mem.trim(u8, line, " "));
    }
    try out.appendSlice(a, "]}}");

    // Démo d'appel hôte (optionnel) : {"hostcall":true} → ping puis release.
    if (std.mem.indexOf(u8, req, "hostcall") != null) {
        if (vh.hostRequest("ping")) |h| {
            _ = try vh.hostReadAll(h, a, 4096);
            vh.hostRelease(h);
        } else |_| {}
    }
    return out.items;
}
