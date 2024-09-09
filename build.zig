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
    const supported_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .gnueabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1136j_s }, // ARMv6
        },
    };

    const std_target = b.standardTargetOptions(.{ .whitelist = supported_targets });
    const optimize = b.option(
        std.builtin.Mode,
        "optimize",
        "Prioritize performance, safety, or binary size (-O flag)",
    ) orelse .ReleaseSmall;

    const targets_to_build: []const std.Target.Query = if (b.user_input_options.contains("target"))
        &.{std_target.query}
    else
        supported_targets;

    for (targets_to_build) |target_query| {
        const target = b.resolveTargetQuery(target_query);

        const zig_yaml_module = b.dependency("zig_yaml", .{
            .target = target,
            .optimize = optimize,
        }).module("yaml");

        const bof_launcher_dep = b.dependency("bof_launcher", .{ .optimize = optimize });
        const bof_launcher_lib = bof_launcher_dep.artifact(
            std.mem.join(
                b.allocator,
                "_",
                &.{ "bof_launcher", osTagStr(target.result.os.tag), cpuArchStr(target.result.cpu.arch) },
            ) catch unreachable,
        );
        const bof_launcher_api_module = bof_launcher_dep.module("bof_launcher_api");

        const exe = b.addExecutable(.{
            .name = std.mem.join(
                b.allocator,
                "_",
                &.{ "cli4bofs", osTagStr(target.result.os.tag), cpuArchStr(target.result.cpu.arch) },
            ) catch unreachable,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        exe.linkLibrary(bof_launcher_lib);
        exe.root_module.addImport("bof-launcher", bof_launcher_api_module);
        exe.root_module.addImport("yaml", zig_yaml_module);

        b.installArtifact(exe);
    }
}
