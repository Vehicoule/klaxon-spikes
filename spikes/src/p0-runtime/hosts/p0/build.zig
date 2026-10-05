const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bytebox_dep = b.dependency("bytebox", .{
        .target = target,
        .optimize = optimize,
        .meter = true,
        .wasi = false,
    });
    const zware_dep = b.dependency("zware", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_bytebox = b.addExecutable(.{
        .name = "p0-bytebox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_bytebox.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_bytebox.root_module.addImport("bytebox", bytebox_dep.module("bytebox"));
    b.installArtifact(exe_bytebox);

    const exe_zware = b.addExecutable(.{
        .name = "p0-zware",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_zware.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    exe_zware.root_module.addImport("zware", zware_dep.module("zware"));
    b.installArtifact(exe_zware);
}
