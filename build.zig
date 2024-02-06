const std = @import("std");

fn osTagStr(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "win",
        .linux => "lin",
        else => unreachable,
    };
}

fn cpuArchStr(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "aarch64",
        .arm => "arm",
        else => unreachable,
    };
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.standardTargetOptions(.{});

    const zig_yaml_module = b.dependency("zig_yaml", .{
        .target = target,
        .optimize = optimize,
        .log = false,
    }).module("yaml");

    const bof_launcher_dep = b.dependency("bof_launcher", .{ .optimize = optimize });
    const bof_launcher_lib = bof_launcher_dep.artifact("bof_launcher_" ++
        comptime osTagStr(@import("builtin").os.tag) ++ "_" ++
        cpuArchStr(@import("builtin").cpu.arch));
    const bof_launcher_api_module = bof_launcher_dep.module("bof_launcher_api");

    const exe = b.addExecutable(.{
        .name = "cli4bofs",
        .root_source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(bof_launcher_lib);
    exe.root_module.addImport("bof-launcher", bof_launcher_api_module);
    exe.root_module.addImport("yaml", zig_yaml_module);

    b.installArtifact(exe);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
