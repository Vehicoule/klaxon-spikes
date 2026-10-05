// player/audio.zig — moteur audio V0 : SDL_AudioStream (push model, SDL
// resample src→device) + décodeur dr_libs (PCM f32 interleaved, fichier
// entier en mémoire). Position = curseur décodé moins la file en attente.
// Feeding : chaque tick maintient ~0.4s de file — pas de callback audio.
const std = @import("std");
pub const media_source = @import("src/media/source.zig");
pub const media_events = @import("src/media/events.zig");
const MediaSource = media_source.MediaSource;
const MediaEvent = media_events.MediaEvent;
const MediaCommand = media_events.MediaCommand;
const Subscriber = media_events.Subscriber;
const JobId = media_events.JobId;

// ---- décodeur (decoder.c) ----
pub extern fn kxdec_open(path: [*:0]const u8) ?*anyopaque;
pub extern fn kxdec_close(h: ?*anyopaque) void;
pub extern fn kxdec_rate(h: ?*anyopaque) c_uint;
pub extern fn kxdec_channels(h: ?*anyopaque) c_uint;
pub extern fn kxdec_frames(h: ?*anyopaque) u64;
pub extern fn kxdec_cursor(h: ?*anyopaque) u64;
pub extern fn kxdec_read(h: ?*anyopaque, dst: [*]f32, want: u64) u64;
pub extern fn kxdec_seek(h: ?*anyopaque, frame: u64) void;

// ---- SDL audio (push model) ----
const SDL_AudioStream = opaque {};
const SDL_AudioDeviceID = u32;
const SDL_AudioSpec = extern struct { format: u32, channels: c_int, freq: c_int };
const SDL_AUDIO_F32: u32 = 0x8120;
const SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK: SDL_AudioDeviceID = 0xFFFFFFFF;
extern fn SDL_OpenAudioDeviceStream(devid: SDL_AudioDeviceID, spec: ?*const SDL_AudioSpec, callback: ?*const anyopaque, userdata: ?*anyopaque) ?*SDL_AudioStream;
extern fn SDL_PutAudioStreamData(stream: *SDL_AudioStream, buf: ?*const anyopaque, len: c_int) bool;
extern fn SDL_GetAudioStreamQueued(stream: *SDL_AudioStream) c_int;
extern fn SDL_ClearAudioStream(stream: *SDL_AudioStream) bool;
extern fn SDL_SetAudioStreamGain(stream: *SDL_AudioStream, gain: f32) bool;
extern fn SDL_PauseAudioStreamDevice(stream: *SDL_AudioStream) bool;
extern fn SDL_ResumeAudioStreamDevice(stream: *SDL_AudioStream) bool;
extern fn SDL_DestroyAudioStream(stream: *SDL_AudioStream) void;
extern fn SDL_GetError() ?[*:0]const u8;
extern fn SDL_InitSubSystem(flags: u32) bool;
const SDL_INIT_AUDIO: u32 = 0x10;

pub const State = media_events.PlaybackState;

pub const Engine = struct {
    dec: ?*anyopaque = null,
    stream: ?*SDL_AudioStream = null,
    state: State = .idle,
    sub: Subscriber = .{},
    job: JobId = 0,
    caps: media_source.Capabilities = .{},
    rate: u32 = 0,
    channels: u32 = 0,
    total_frames: u64 = 0,
    feed_buf: [8192 * 2]f32 = undefined, // jusqu'à 8192 frames stereo
    decode_thread: ?std.Thread = null,
    decode_path: ?[]u8 = null,
    decode_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    decode_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    gain: f32 = 1.0,
    // stats observables (vérif headless)
    fed_frames: u64 = 0,
    last_pos_emit_us: media_events.Micros = 0,
    path_alloc: std.mem.Allocator = undefined,

    // ---- API domaine : load(MediaSource) / command() / subscribe() ----
    // (contrats typés µs — spec V19 V0)

    pub fn subscribe(self: *Engine, sub: Subscriber) void {
        self.sub = sub;
    }

    fn emit(self: *Engine, ev: MediaEvent) void {
        self.sub.emit(ev);
    }

    fn fail(self: *Engine, code: media_events.ErrorCode, msg: []const u8) void {
        self.state = .failed;
        self.emit(.{ .err = .{ .code = code, .msg = msg } });
        self.emit(.{ .state = .failed });
    }

    /// load(source) — dispatcher sur la variante. HTTP refusé honnêtement
    /// en V0 (pas de fetch réseau côté engine ; le provider viendra en V2).
    pub fn load(self: *Engine, alloc: std.mem.Allocator, src: MediaSource) !void {
        self.job += 1;
        switch (src) {
            .local_file => |l| {
                // pas de pré-gate format : décodeurs vendored en primaire,
                // décodeur OS (ffmpeg) en fallback — kxdec_open renvoie NULL
                // honnêtement si rien ne sait lire le fichier.
                self.caps = l.caps;
                self.state = .loading;
                self.emit(.{ .state = .loading });
                self.emit(.{ .capabilities = l.caps });
                try self.startDecode(alloc, l.path);
            },
            .http => {
                self.caps = .{};
                self.fail(.unsupported_source, "http pas implémenté en V0");
            },
        }
    }

    /// command(Play|Pause|Seek|Stop) — seek refusé si la source n'est pas
    /// seekable (capabilities déclarées, pas d'hypothèse réseau=disque).
    pub fn command(self: *Engine, cmd: MediaCommand) void {
        switch (cmd) {
            .play => self.setPlaying(true),
            .pause => self.setPlaying(false),
            .stop => self.close(),
            .seek => |us| {
                if (!self.caps.seekable) return;
                self.seekUs(us);
            },
        }
    }

    fn startDecode(self: *Engine, alloc: std.mem.Allocator, path: []const u8) !void {
        self.closeStreaming();
        self.path_alloc = alloc;
        self.decode_ready.store(false, .release);
        self.decode_failed.store(false, .release);
        self.decode_path = try alloc.dupe(u8, path);
        self.decode_thread = std.Thread.spawn(.{}, decodeWorker, .{self}) catch blk: {
            // pas de thread dispo → décode synchrone (dégradé honnête)
            decodeWorker(self);
            break :blk null;
        };
    }

    fn decodeWorker(self: *Engine) void {
        const path = self.decode_path orelse return;
        var zbuf: [4096]u8 = undefined;
        if (path.len >= zbuf.len) { self.decode_failed.store(true, .release); return; }
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        const h = kxdec_open(@ptrCast(&zbuf));
        if (h == null) { self.decode_failed.store(true, .release); return; }
        self.dec = h;
        self.rate = kxdec_rate(h);
        self.channels = kxdec_channels(h);
        self.total_frames = kxdec_frames(h);
        self.decode_ready.store(true, .release);
    }

    /// Armé quand decode_ready : crée le stream SDL à la spec du fichier.
    pub fn armIfReady(self: *Engine) bool {
        if (!self.decode_ready.load(.acquire)) return false;
        const spec = SDL_AudioSpec{
            .format = SDL_AUDIO_F32,
            .channels = @intCast(self.channels),
            .freq = @intCast(self.rate),
        };
        _ = SDL_InitSubSystem(SDL_INIT_AUDIO); // host SDL_Init peut ne pas couvrir audio
        self.stream = SDL_OpenAudioDeviceStream(
            SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null);
        if (self.stream == null) {
            self.state = .ended; // pas de device : échec franc, visible
            if (SDL_GetError()) |e| std.debug.print("audio: open failed: {s}\n", .{e});
            return false;
        }
        _ = SDL_SetAudioStreamGain(self.stream.?, self.gain);
        _ = SDL_ResumeAudioStreamDevice(self.stream.?);
        self.state = .playing;
        self.fed_frames = 0;
        self.last_pos_emit_us = 0;
        self.emit(.{ .state = .playing });
        self.emit(.{ .position = .{ .position_us = 0, .duration_us = self.durationUs() } });
        return true;
    }

    /// Alimente la file (~0.4s cible). À appeler à chaque tick UI.
    pub fn feed(self: *Engine) void {
        const s = self.stream orelse return;
        if (self.state != .playing) return;
        const dec = self.dec orelse return;
        // budget file : 0.4s de sortie device (post-conversion, bytes)
        const queued = SDL_GetAudioStreamQueued(s);
        const want_bytes: i64 = @intFromFloat(0.4 * 48000 * 2 * 4); // conservative
        if (queued < want_bytes) {
            const ch: u64 = if (self.channels == 0) 2 else self.channels;
            const frames_want: u64 = 4096;
            const n = kxdec_read(dec, &self.feed_buf, frames_want);
            if (n == 0) {
                if (queued <= 0 and self.state == .playing) {
                    self.state = .ended; // tout consommé
                    self.emit(.{ .state = .ended });
                }
                return;
            }
            const bytes: c_int = @intCast(n * ch * 4);
            _ = SDL_PutAudioStreamData(s, &self.feed_buf, bytes);
            self.fed_frames += n;
        }
        // position events throttlés ~250ms (spec MediaEvent.position)
        const pos = self.positionUs();
        const dur = self.durationUs();
        if (pos >= self.last_pos_emit_us + 250_000 or pos < self.last_pos_emit_us) {
            self.last_pos_emit_us = pos;
            self.emit(.{ .position = .{ .position_us = pos, .duration_us = dur } });
        }
    }

    /// Position audible estimée — µs typées (curseur décodé − file résiduelle).
    pub fn positionUs(self: *Engine) media_events.Micros {
        const dec = self.dec orelse return 0;
        if (self.rate == 0) return 0;
        const cur = kxdec_cursor(dec);
        const cur_us = cur * 1_000_000 / self.rate;
        const s = self.stream orelse return cur_us;
        const queued_us: u64 = @intCast(@divTrunc(@as(i64, SDL_GetAudioStreamQueued(s)) * 1_000_000, 48000 * 2 * 4));
        return if (cur_us > queued_us) cur_us - queued_us else 0;
    }

    pub fn durationUs(self: *Engine) media_events.Micros {
        if (self.rate == 0) return 0;
        return self.total_frames * 1_000_000 / self.rate;
    }

    pub fn seekUs(self: *Engine, us: media_events.Micros) void {
        const dec = self.dec orelse return;
        if (self.stream) |s| _ = SDL_ClearAudioStream(s);
        const f: u64 = us * self.rate / 1_000_000;
        kxdec_seek(dec, f);
        if (self.state == .ended and self.stream != null) {
            _ = SDL_ResumeAudioStreamDevice(self.stream.?);
            self.state = .playing;
            self.emit(.{ .state = .playing });
        }
    }

    pub fn setPlaying(self: *Engine, play: bool) void {
        const s = self.stream orelse return;
        if (play and self.state == .paused) {
            _ = SDL_ResumeAudioStreamDevice(s);
            self.state = .playing;
        } else if (!play and self.state == .playing) {
            _ = SDL_PauseAudioStreamDevice(s);
            self.state = .paused;
        }
    }

    pub fn setGain(self: *Engine, gain: f32) void {
        self.gain = gain;
        if (self.stream) |s| _ = SDL_SetAudioStreamGain(s, gain);
    }

    /// indices observables pour la vérif headless
    pub fn queuedBytes(self: *Engine) i32 {
        const s = self.stream orelse return 0;
        return SDL_GetAudioStreamQueued(s);
    }

    /// Libère le flux/décodeur en cours sans toucher aux atomics de job
    /// (appelé par load() avant de repartir sur une nouvelle source).
    fn closeStreaming(self: *Engine) void {
        if (self.decode_thread) |t| { self.decode_thread = null; t.join(); }
        if (self.stream) |s| { SDL_DestroyAudioStream(s); self.stream = null; }
        if (self.dec) |d| { kxdec_close(d); self.dec = null; }
        if (self.decode_path) |p| { self.path_alloc.free(p); self.decode_path = null; }
        self.decode_ready.store(false, .release);
        self.decode_failed.store(false, .release);
        self.total_frames = 0;
        self.fed_frames = 0;
    }

    pub fn close(self: *Engine) void {
        self.closeStreaming();
        self.state = .idle;
        self.caps = .{};
    }
};
