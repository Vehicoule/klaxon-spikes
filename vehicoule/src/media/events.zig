//! MediaEvent / MediaCommand / JobId — contrats typés µs (spec V19 V0).
//! `subscribe()` reçoit des événements ; `command()` reçoit des ordres.
//! Position et durée sont des microsecondes (u64) — le tag de type est le
//! champ `_us` systématique, jamais un float en secondes.

const source = @import("source.zig");

/// Identité d'un job async (load/download/…). Annulation idempotente :
/// un résultat tardif d'un job annulé est ignoré selon la révision.
pub const JobId = u64;

pub const PlaybackState = enum { idle, loading, playing, paused, ended, failed };

pub const MediaCommand = union(enum) {
    play,
    pause,
    seek: Micros,
    stop,
};

/// Microsecondes — temps monotonique média partout dans l'app.
pub const Micros = u64;

pub const ErrorCode = enum {
    open_failed,
    decode_failed,
    unsupported_format,
    unsupported_source, // http pas encore implémenté côté engine
    io,
    canceled,
};

pub const MediaError = struct {
    code: ErrorCode,
    msg: []const u8 = "",
};

pub const MediaEvent = union(enum) {
    state: PlaybackState,
    position: Position,
    capabilities: source.Capabilities,
    err: MediaError,

    pub const Position = struct {
        position_us: Micros,
        duration_us: Micros,
    };
};

/// Sink unique en V0 — un subscriber = callback appelé sur le thread UI.
pub const Subscriber = struct {
    ctx: ?*anyopaque = null,
    cb: ?*const fn (ctx: ?*anyopaque, ev: MediaEvent) void = null,

    pub fn emit(self: *const Subscriber, ev: MediaEvent) void {
        if (self.cb) |cb| cb(self.ctx, ev);
    }
};
