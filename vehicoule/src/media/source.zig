//! MediaSource — descripteur de source média (spec V19 V0).
//! Distingue fichier local et source HTTP ; porte origine, références de
//! credentials (jamais les secrets inline), expiration/validators, format
//! attendu et capabilities réelles. Réseau et disque ne promettent pas les
//! mêmes capacités — chaque variante déclare les siennes.

pub const Format = enum { unknown, mp3, flac, wav, vorbis, opus, aac, alac };

/// Capacités déclarées d'une source — lues par la session avant d'agir.
pub const Capabilities = struct {
    seekable: bool = false, // seek arbitraire autorisé
    offline_ok: bool = false, // jouable sans réseau
    resumable: bool = false, // Range/resume supporté (HTTP)
};

pub const MediaSource = union(enum) {
    local_file: Local,
    http: Http,

    pub const Local = struct {
        path: []const u8,
        expected_format: Format = .unknown,
        caps: Capabilities = .{ .seekable = true, .offline_ok = true, .resumable = true },
    };

    /// La policy hôte valide `origin` avant chaque fetch ; les credentials
    /// sont référencés par nom et résolus par l'hôte au moment de l'appel —
    /// un plugin ne reçoit jamais le secret, et un refresh d'URL signée ne
    /// recopie pas les credentials vers une nouvelle origine.
    pub const Http = struct {
        url: []const u8,
        origin: []const u8,
        credential_ref: ?[]const u8 = null,
        expires_us: ?u64 = null, // deadline des URLs signées
        etag: ?[]const u8 = null, // validator contenu
        expected_format: Format = .unknown,
        caps: Capabilities = .{},
    };
};

pub fn formatForPath(path: []const u8) Format {
    var ext: []const u8 = "";
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '.') { ext = path[i - 1 ..]; break; }
        if (path[i - 1] == '/') break;
    }
    if (ext.len == 0) return .unknown;
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(ext, ".mp3")) return .mp3;
    if (eql(ext, ".flac")) return .flac;
    if (eql(ext, ".wav")) return .wav;
    if (eql(ext, ".ogg") or eql(ext, ".oga")) return .vorbis;
    if (eql(ext, ".opus")) return .opus;
    if (eql(ext, ".m4a") or eql(ext, ".aac")) return .aac;
    return .unknown;
}

const std = @import("std");
