// sdl.zig — sous-ensemble minimal de l'API SDL3 utilisée par Klaxon.
// Déclarations manuelles (subset) — `zig translate-c` produira le fichier
// complet quand la surface utilisée grossira (cf. spikes/k1-sdl/app/kx_sdl.zig).

pub const Window = opaque {};
pub const GLContext = opaque {};

pub const SDL_INIT_VIDEO: u32 = 0x20;

pub const SDL_WINDOW_OPENGL: u64 = 0x2;
pub const SDL_WINDOW_RESIZABLE: u64 = 0x20;
pub const SDL_WINDOW_FULLSCREEN: u64 = 0x1;
pub const SDL_WINDOW_VULKAN: u64 = 0x10000000;
pub const SDL_SystemTheme = enum(c_int) { unknown = 0, light = 1, dark = 2 };
pub extern fn SDL_GetSystemTheme() SDL_SystemTheme;

pub const SDL_WINDOW_METAL: u64 = 0x20000000;
pub const SDL_WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x2000;

// SDL_GLAttr (c_uint)
pub const SDL_GL_CONTEXT_MAJOR_VERSION: c_uint = 17;
pub const SDL_GL_CONTEXT_MINOR_VERSION: c_uint = 18;
pub const SDL_GL_CONTEXT_PROFILE_MASK: c_uint = 21;
pub const SDL_GL_DOUBLEBUFFER: c_uint = 5;
pub const SDL_GL_STENCIL_SIZE: c_uint = 7;
pub const SDL_GL_CONTEXT_PROFILE_ES: c_int = 0x4;
pub const SDL_GL_CONTEXT_PROFILE_CORE: c_int = 0x1;
pub const SDL_GL_CONTEXT_PROFILE_COMPATIBILITY: c_int = 0x2;

// event types (SDL_EventType enum values, u32)
pub const SDL_EVENT_QUIT: u32 = 0x100;
pub const SDL_EVENT_WINDOW_SHOWN: u32 = 0x202;
pub const SDL_EVENT_WINDOW_HIDDEN: u32 = 0x203;
pub const SDL_EVENT_WINDOW_EXPOSED: u32 = 0x204;
pub const SDL_EVENT_WINDOW_MOVED: u32 = 0x205;
pub const SDL_EVENT_WINDOW_RESIZED: u32 = 0x206;
pub const SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED: u32 = 0x207;
pub const SDL_EVENT_WINDOW_METAL_VIEW_RESIZED: u32 = 0x208;
pub const SDL_EVENT_WINDOW_MINIMIZED: u32 = 0x209;
pub const SDL_EVENT_WINDOW_MAXIMIZED: u32 = 0x20a;
pub const SDL_EVENT_WINDOW_RESTORED: u32 = 0x20b;
pub const SDL_EVENT_WILL_ENTER_BACKGROUND: u32 = 0x110;
pub const SDL_EVENT_DID_ENTER_BACKGROUND: u32 = 0x111;
pub const SDL_EVENT_WILL_ENTER_FOREGROUND: u32 = 0x112;
pub const SDL_EVENT_DID_ENTER_FOREGROUND: u32 = 0x113;
pub const SDL_EVENT_LOW_MEMORY: u32 = 0x11a;
pub const SDL_EVENT_KEY_DOWN: u32 = 0x300;
pub const SDL_EVENT_KEY_UP: u32 = 0x301;
pub const SDL_EVENT_TEXT_EDITING: u32 = 0x302; // composition IME (pre-edit)
pub const SDL_EVENT_TEXT_INPUT: u32 = 0x303;
pub const SDL_EVENT_TEXT_EDITING_CANDIDATES: u32 = 0x307;

// Keycodes utiles aux champs texte (SDL3 SDL_keycode.h).
pub const SDLK_TAB: u32 = 0x09;
pub const SDLK_BACKSPACE: u32 = 0x08;
pub const SDLK_RETURN: u32 = 0x0D;
pub const SDLK_DELETE: u32 = 0x7F;
pub const SDLK_HOME: u32 = 0x4000004A;
pub const SDLK_END: u32 = 0x4000004D;
pub const SDLK_RIGHT: u32 = 0x4000004F;
pub const SDLK_LEFT: u32 = 0x40000050;
pub const SDLK_DOWN: u32 = 0x40000051;
pub const SDLK_UP: u32 = 0x40000052;
pub const SDLK_SPACE: u32 = 0x20;
// SDL_Keymod (u16 dans SDL_KeyboardEvent.mod).
pub const KMOD_SHIFT: u16 = 0x0003; // LSHIFT|RSHIFT
pub const KMOD_CTRL: u16 = 0x00C0;  // LCTRL|RCTRL
pub const KMOD_ALT: u16 = 0x0300;
pub const KMOD_GUI: u16 = 0x0C00;

pub const SDL_EVENT_MOUSE_MOTION: u32 = 0x400;
pub const SDL_EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
pub const SDL_EVENT_MOUSE_BUTTON_UP: u32 = 0x402;
pub const SDL_EVENT_MOUSE_WHEEL: u32 = 0x403;
pub const SDL_EVENT_FINGER_DOWN: u32 = 0x700;
pub const SDL_EVENT_FINGER_UP: u32 = 0x701;
pub const SDL_EVENT_FINGER_MOTION: u32 = 0x702;
pub const SDL_EVENT_FINGER_CANCELED: u32 = 0x703;

// hint : off → plus de synthèse tactile→souris (les FINGER_* restent
// livrés ; on les traduit nous-mêmes — certains drivers/OEM perdent le
// BUTTON_UP synthétisé, cause de "clics morts" mesurée sur retail).
pub const SDL_HINT_TOUCH_MOUSE_EVENTS = "SDL_TOUCH_MOUSE_EVENTS";

// SDL_Event union (SDL3) — tête commune + window event payload.
// Suffisant pour les events qu'on lit ; le C side garde la taille réelle (128o).
pub const SDL_Event = extern union {
    type: u32,
    window: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        data1: i32,
        data2: i32,
    },
    key: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        which: u32,
        scancode: u32,
        key: u32,
        mod: u16,
        raw: u16,
        down: bool,
        repeat: bool,
    },
    text: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        text: [*c]const u8,
    },
    edit: extern struct {
        // SDL_TextEditingEvent : composition IME
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        text: [*c]const u8,
        start: i32,  // caret dans le texte d'édition (-1 = non défini)
        length: i32, // longueur remplacée (-1 = non défini)
    },
    button: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        which: u32,
        button: u8,
        down: bool,
        clicks: u8,
        padding: u8,
        x: f32,
        y: f32,
    },
    motion: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        which: u32,
        state: u32,
        x: f32,
        y: f32,
        xrel: f32,
        yrel: f32,
    },
    wheel: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        windowID: u32,
        which: u32,
        x: f32,
        y: f32,
        direction: u32,
        mouse_x: f32,
        mouse_y: f32,
        integer_x: i32,
        integer_y: i32,
    },
    // SDL_TouchFingerEvent : x/y/dx/dy/pressure NORMALISÉS 0..1 (×win px).
    tfinger: extern struct {
        type: u32,
        reserved: u32,
        timestamp: u64,
        touchID: u64,
        fingerID: u64,
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
        pressure: f32,
        windowID: u32,
    },
    padding: [128]u8,
};

pub extern fn SDL_Init(flags: u32) bool;
pub extern fn SDL_Log(fmt: [*:0]const u8, ...) void;
pub extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
pub extern fn SDL_Quit() void;
pub extern fn SDL_SetAppMetadata(name: [*c]const u8, version: [*c]const u8, ident: [*c]const u8) bool;
pub extern fn SDL_CreateWindow(title: [*c]const u8, w: c_int, h: c_int, flags: u64) ?*Window;
pub extern fn SDL_DestroyWindow(w: ?*Window) void;
pub extern fn SDL_GetWindowSize(w: ?*Window, w_out: [*c]c_int, h_out: [*c]c_int) bool;
pub extern fn SDL_GetWindowID(w: ?*Window) u32;
pub extern fn SDL_GetWindowSizeInPixels(w: ?*Window, w_out: [*c]c_int, h_out: [*c]c_int) bool;
pub extern fn SDL_GetWindowDisplayScale(w: ?*Window) f32;
pub extern fn SDL_GetWindowFlags(w: ?*Window) u64;
pub const SDL_WINDOW_SHOWN_FLAG: u64 = 0x4; // SDL_WINDOW_SHOWN (SDL_WindowFlags Uint64)
pub extern fn SDL_PollEvent(ev: ?*SDL_Event) bool;
pub extern fn SDL_WaitEvent(ev: ?*SDL_Event) bool;
pub extern fn SDL_PushEvent(ev: ?*SDL_Event) bool; // injection (tests/dev)
pub extern fn SDL_Delay(ms: u32) void;
pub extern fn SDL_GetError() [*c]const u8;

// Propriétés fenêtre natives (HWND Windows, etc.) + attente avec timeout.
pub const SDL_PropertiesID = u32;
pub const SDL_PROP_WINDOW_WIN32_HWND_POINTER: [*c]const u8 = "SDL.window.win32.hwnd";
pub extern fn SDL_GetWindowProperties(window: ?*Window) SDL_PropertiesID;
pub extern fn SDL_GetPointerProperty(props: SDL_PropertiesID, name: [*c]const u8, default_value: ?*anyopaque) ?*anyopaque;
pub extern fn SDL_WaitEventTimeout(event: ?*SDL_Event, timeoutMS: c_int) bool;

pub extern fn SDL_GL_SetAttribute(attr: c_uint, value: c_int) bool;
pub const MetalView = opaque {};
pub extern fn SDL_Metal_CreateView(w: ?*Window) ?*MetalView;
pub extern fn SDL_Metal_DestroyView(v: ?*MetalView) void;
pub extern fn SDL_Metal_GetLayer(v: ?*MetalView) ?*anyopaque;

pub extern fn SDL_GL_CreateContext(w: ?*Window) ?*GLContext;
pub extern fn SDL_GL_DestroyContext(ctx: ?*GLContext) bool;
pub extern fn SDL_GL_MakeCurrent(w: ?*Window, ctx: ?*GLContext) bool;
pub extern fn SDL_GL_SetSwapInterval(interval: c_int) bool;
pub extern fn SDL_GL_SwapWindow(w: ?*Window) bool;
pub extern fn SDL_GL_GetProcAddress(proc: [*c]const u8) ?*anyopaque;

// vulkan (Android : fenêtre SDL_WINDOW_VULKAN, surface via SDL)
pub extern fn SDL_Vulkan_LoadLibrary(path: ?[*:0]const u8) bool;
pub extern fn SDL_Vulkan_CreateSurface(w: ?*Window, instance: ?*anyopaque, allocator: ?*const anyopaque, surface: ?*?*anyopaque) bool;

// text input / IME
pub const SDL_Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
pub extern fn SDL_StartTextInput(w: ?*Window) bool;
pub extern fn SDL_StopTextInput(w: ?*Window) bool;
pub extern fn SDL_TextInputActive(w: ?*Window) bool;
pub extern fn SDL_SetTextInputArea(w: ?*Window, rect: ?*const SDL_Rect, cursor: c_int) bool;
pub extern fn SDL_GetClipboardText() [*c]u8;
