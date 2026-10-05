// wamr.zig — externs WAMR fast-interp (mêmes flags que p0-wamr/build_wamr.sh :
// INTERP=1 FAST_INTERP=1 AOT=0 JIT=0 BULK_MEMORY(+OPT)=1 REF_TYPES=1
// CALL_INDIRECT_OVERLONG=1 WAKEUP_BLOCKING_OP=1 INSTRUCTION_METERING=1).
const std = @import("std");

pub const WasmModule = opaque {};
pub const WasmModuleInst = opaque {};
pub const WasmExecEnv = opaque {};
pub const WasmFunction = opaque {};

pub const MemAllocOption = extern union {
    pool: extern struct { heap_buf: ?*anyopaque, heap_size: u32 },
    allocator: extern struct {
        malloc_func: ?*anyopaque,
        realloc_func: ?*anyopaque,
        free_func: ?*anyopaque,
        user_data: ?*anyopaque,
    },
};

pub const RuntimeInitArgs = extern struct {
    mem_alloc_type: c_int = 0, // 0=pool 1=allocator 2=system
    mem_alloc_option: MemAllocOption = .{ .allocator = .{
        .malloc_func = null,
        .realloc_func = null,
        .free_func = null,
        .user_data = null,
    } },
    native_module_name: ?[*:0]const u8 = null,
    native_symbols: ?*anyopaque = null,
    n_native_symbols: u32 = 0,
    max_thread_num: u32 = 0,
    ip_addr: [128]u8 = std.mem.zeroes([128]u8),
    unused: c_int = 0,
    instance_port: c_int = 0,
    fast_jit_code_cache_size: u32 = 0,
    gc_heap_size: u32 = 0,
    running_mode: c_int = 0,
    llvm_jit_opt_level: u32 = 0,
    llvm_jit_size_level: u32 = 0,
    segue_flags: u32 = 0,
    enable_linux_perf: bool = false,
};

// NativeSymbol : {name, func, signature, attachment} — 4 pointeurs.
// func : pointeur brut d'une fn zig callconv(.c) dont le 1er arg est env.
pub const NativeSymbol = extern struct {
    name: ?[*:0]const u8 = null,
    func: ?*const anyopaque = null,
    signature: ?[*:0]const u8 = null,
    attachment: ?*anyopaque = null,
};

pub extern fn wasm_runtime_full_init(init_args: *RuntimeInitArgs) bool;
pub extern fn wasm_runtime_destroy() void;
pub extern fn wasm_runtime_register_natives(
    module_name: [*:0]const u8,
    native_symbols: [*]const NativeSymbol,
    n_native_symbols: u32,
) bool;

pub extern fn wasm_runtime_load(
    buf: [*]const u8,
    size: u32,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*WasmModule;
pub extern fn wasm_runtime_unload(module: *WasmModule) void;

pub extern fn wasm_runtime_instantiate(
    module: *const WasmModule,
    stack_size: u32,
    heap_size: u32,
    error_buf: [*]u8,
    error_buf_size: u32,
) ?*WasmModuleInst;
pub extern fn wasm_runtime_deinstantiate(inst: *WasmModuleInst) void;

pub extern fn wasm_runtime_lookup_function(
    inst: *WasmModuleInst,
    name: [*:0]const u8,
) ?*WasmFunction;

pub extern fn wasm_runtime_create_exec_env(
    inst: *WasmModuleInst,
    stack_size: u32,
) ?*WasmExecEnv;
pub extern fn wasm_runtime_destroy_exec_env(env: *WasmExecEnv) void;

pub extern fn wasm_runtime_set_instruction_count_limit(
    env: *WasmExecEnv,
    limit: i32,
) bool;

pub extern fn wasm_runtime_call_wasm(
    env: *WasmExecEnv,
    func: *WasmFunction,
    argc: u32,
    argv: [*]u32,
) bool;

pub extern fn wasm_runtime_get_exception(inst: *WasmModuleInst) ?[*:0]const u8;

pub extern fn wasm_runtime_validate_app_addr(
    inst: *WasmModuleInst,
    app_offset: u32,
    size: u32,
) bool;

pub extern fn wasm_runtime_addr_app_to_native(
    inst: *WasmModuleInst,
    app_offset: u32,
) ?*anyopaque;

pub extern fn wasm_runtime_get_module_inst(env: *WasmExecEnv) ?*WasmModuleInst;
/// custom_data = attachement par instance (partagé entre les exec env du
/// module) — sert à porter la policy par-plugin.
pub extern fn wasm_runtime_set_custom_data(inst: *WasmModuleInst, data: ?*anyopaque) void;
pub extern fn wasm_runtime_get_custom_data(inst: *WasmModuleInst) ?*anyopaque;

// Terminaison cross-thread : à appeler depuis un thread autre que celui qui
// exécute call_wasm (prouvé <200ms sur fast-interp, cf P0-RESULT).
pub extern fn wasm_runtime_terminate(inst: *WasmModuleInst) void;
