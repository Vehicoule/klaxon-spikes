// klaxon.zig — racine du module Klaxon (framework UI Zig/Skia).
// Point d'entrée unique des ré-exports ; l'app n'importe que ceci.
pub const kx = @import("kx.zig");
pub const sdl = @import("sdl.zig");
pub const host = @import("host.zig");
pub const ui = @import("ui.zig");
pub const widgets = @import("widgets.zig");

pub const Host = host.Host;
pub const Event = host.Event;
pub const Stats = host.Stats;
pub const RssMark = host.RssMark;
pub const rssMark = host.rssMark;
pub const rssLedger = host.rssLedger;
pub const Backend = kx.Backend;
pub const is_wasm = host.is_wasm;
