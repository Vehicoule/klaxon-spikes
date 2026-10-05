// policy.zig — manifeste de permissions du plugin (ADR-0007).
// Format attendu dans le manifest : "permissions": ["network:<domain>",
// "fs:read:<prefix>", "fs:write:<prefix>", "scan:<prefix>"]. Le parser est
// volontairement minimal (extraction de la liste de chaînes) : il n'exige pas
// de JSON complet tant que le manifest n'est pas figé.
const std = @import("std");

pub const Kind = enum { network, fs_read, fs_write, scan };

pub const Grant = struct { kind: Kind, pattern: []const u8 };

pub const Policy = struct {
    grants: std.ArrayList(Grant) = .empty,

    pub fn deinit(p: *Policy, a: std.mem.Allocator) void {
        for (p.grants.items) |g| a.free(g.pattern);
        p.grants.deinit(a);
    }

    /// Parse les chaînes de la liste "permissions". Texte libre : on cherche
    /// `"permissions"`, puis le `[...]` qui suit et chaque "..." dedans.
    pub fn parse(a: std.mem.Allocator, manifest: []const u8) !Policy {
        var p: Policy = .{};
        errdefer p.deinit(a);

        const key = "\"permissions\"";
        const ki = std.mem.indexOf(u8, manifest, key) orelse return p;
        var i = ki + key.len;
        const open = std.mem.indexOfScalarPos(u8, manifest, i, '[') orelse return p;
        const close = std.mem.indexOfScalarPos(u8, manifest, open, ']') orelse return p;
        const body = manifest[open + 1 .. close];
        i = 0;
        while (i < body.len) {
            const q1 = std.mem.indexOfScalarPos(u8, body, i, '"') orelse break;
            const q2 = std.mem.indexOfScalarPos(u8, body, q1 + 1, '"') orelse break;
            try p.addGrant(a, body[q1 + 1 .. q2]);
            i = q2 + 1;
        }
        return p;
    }

    fn addGrant(p: *Policy, a: std.mem.Allocator, s: []const u8) !void {
        const kind: Kind, const pat = blk: {
            if (std.mem.startsWith(u8, s, "network:")) break :blk .{ .network, s["network:".len..] };
            if (std.mem.startsWith(u8, s, "fs:read:")) break :blk .{ .fs_read, s["fs:read:".len..] };
            if (std.mem.startsWith(u8, s, "fs:write:")) break :blk .{ .fs_write, s["fs:write:".len..] };
            if (std.mem.startsWith(u8, s, "scan:")) break :blk .{ .scan, s["scan:".len..] };
            return; // grant inconnu : ignoré (pas d'effet)
        };
        if (pat.len == 0) return;
        const dup = try a.dupe(u8, pat);
        try p.grants.append(a, .{ .kind = kind, .pattern = dup });
    }

    /// `network` : match exact, "?", "*" global, "*.<domain>" sous-domaines.
    /// `fs_*` / `scan` : préfixe de chemin ("/" terminal optionnel côté grant).
    pub fn allows(p: *const Policy, kind: Kind, target: []const u8) bool {
        for (p.grants.items) |g| {
            if (g.kind != kind) continue;
            const pat = g.pattern;
            switch (kind) {
                .network => {
                    if (std.mem.eql(u8, pat, "*")) return true;
                    if (std.mem.eql(u8, pat, target)) return true;
                    if (pat.len > 2 and pat[0] == '*' and pat[1] == '.') {
                        const suffix = pat[1..]; // ".example.com"
                        if (target.len > suffix.len and
                            std.mem.endsWith(u8, target, suffix)) return true;
                    }
                },
                .fs_read, .fs_write, .scan => {
                    if (std.mem.eql(u8, pat, "*")) return true;
                    var pre = pat;
                    if (pre.len > 1 and pre[pre.len - 1] == '/') pre = pre[0 .. pre.len - 1];
                    if (std.mem.startsWith(u8, target, pre)) {
                        // préfixe doit s'aligner sur une frontière de segment
                        if (target.len == pre.len or target[pre.len] == '/') return true;
                    }
                },
            }
        }
        return false;
    }
};

test "policy parse + match" {
    var p = try Policy.parse(std.testing.allocator,
        \\{"id":"x","permissions":["network:*.example.com","fs:read:/music/","scan:/library","http:call"],"custom":1}
    );
    defer p.deinit(std.testing.allocator);
    try std.testing.expect(p.allows(.network, "api.example.com"));
    try std.testing.expect(!p.allows(.network, "example.com"));
    try std.testing.expect(!p.allows(.network, "evil.com"));
    try std.testing.expect(p.allows(.fs_read, "/music/rock/a.mp3"));
    try std.testing.expect(!p.allows(.fs_read, "/musicx/b.mp3"));
    try std.testing.expect(p.allows(.scan, "/library/sub"));
    try std.testing.expect(!p.allows(.fs_write, "/music/rock/a.mp3"));
}
