const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "cli4bofs",
        .root_source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const Options = @import("libs/bof-launcher/bof-launcher/build.zig").Options;
    const options = Options{ .target = target, .optimize = optimize };
    std.debug.print("{any}\n", .{options.target.os_tag});
    std.debug.print("{any}\n", .{options.target.getOsTag()});
    const bof_launcher_lib = @import("libs/bof-launcher/bof-launcher/build.zig").build(b, options);
    const bof_launcher_api_module = b.createModule(.{
        .source_file = .{ .path = thisDir() ++ "/libs/bof-launcher/bof-launcher/src/bof_launcher_api.zig" },
    });
    exe.linkLibrary(bof_launcher_lib);
    exe.addModule("bof-launcher", bof_launcher_api_module);

    const yaml_module = b.addModule("yaml", .{
        .source_file = std.build.FileSource{ .path = thisDir() ++ "/libs/zig-yaml/src/yaml.zig" },
    });
    exe.addModule("yaml", yaml_module);

    b.installArtifact(exe);
    //const zwin32_pkg = @import("../../build.zig").zwin32_pkg;
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
