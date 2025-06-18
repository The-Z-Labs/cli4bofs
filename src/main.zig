const std = @import("std");
const bofs = @import("bof-launcher");
const yaml = @import("yaml");

pub const std_options = std.Options{
    .log_level = .info,
};

const io = std.io;
const mem = std.mem;

const version = std.SemanticVersion{ .major = 0, .minor = 10, .patch = 1 };

const BofRecord = struct {
    name: []const u8,
    srcfile: ?[]const u8,
    description: []const u8,
    author: []const u8,
    tags: []const []const u8,
    OS: []const u8,
    entrypoint: ?[]const u8,
    api: ?[]const []const u8,
    sources: []const []const u8,
    examples: []const u8,
    arguments: ?[]const struct {
        name: []const u8,
        desc: []const u8,
        type: []const u8,
        required: []const u8,
        api: ?[]const u8,
    },
    errors: ?[]const struct {
        name: []const u8,
        code: u8,
        message: []const u8,
    },
};

fn checkArgType(arg: [:0]const u8, doc_type: []const u8) bool {
    var iter = mem.tokenizeScalar(u8, arg, ':');
    const type_prefix = iter.next() orelse unreachable;

    var current_type: [:0]const u8 = undefined;
    if (mem.eql(u8, arg, type_prefix) or mem.eql(u8, type_prefix, "str") or mem.eql(u8, type_prefix, "z")) {
        current_type = "string";
    } else if (mem.eql(u8, type_prefix, "short") or mem.eql(u8, type_prefix, "s")) {
        current_type = "short";
    } else if (mem.eql(u8, type_prefix, "integer") or mem.eql(u8, type_prefix, "i")) {
        current_type = "integer";
    } else if (mem.eql(u8, type_prefix, "wstr") or mem.eql(u8, type_prefix, "Z")) {
        current_type = "wstring";
    } else if (mem.eql(u8, type_prefix, "file") or mem.eql(u8, type_prefix, "b")) {
        current_type = "buffer";
    }

    if (!mem.eql(u8, current_type, doc_type))
        return false;

    return true;
}

fn runBofFromFile(
    allocator: std.mem.Allocator,
    bof_path: [:0]const u8,
    arg_data: ?[]u8,
) !u8 {
    const file = try std.fs.openFileAbsoluteZ(bof_path, .{});
    defer file.close();

    const file_data = try file.reader().readAllAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(file_data);

    const object = try bofs.Object.initFromMemory(file_data);
    defer object.release();

    const context = try object.run(arg_data);
    defer context.release();

    if (context.getOutput()) |output| {
        try std.io.getStdOut().writer().print("{s}", .{output});
    }
    return context.getExitCode();
}

fn loadFileContent(
    allocator: std.mem.Allocator,
    file_path: [:0]const u8,
) ![]const u8 {
    const file = try std.fs.openFileAbsoluteZ(file_path, .{});
    defer file.close();

    var file_data = std.ArrayList(u8).init(allocator);
    defer file_data.deinit();

    try file.reader().readAllArrayList(&file_data, 16 * 1024 * 1024);
    //try file_data.append(0);

    return file_data.toOwnedSlice();
}

fn usage(name: [:0]const u8) !void {
    const stdout = io.getStdOut().writer();
    try stdout.print("\nUsage: {s} command [options]\n\n", .{name});
    try stdout.print("Commands:\n\n", .{});
    try stdout.print("help    <COMMAND>                   Display help about given command\n", .{});
    try stdout.print("exec    <BOF>                       Execute given BOF from a filesystem\n", .{});
    try stdout.print("inject  file:<abs_bof_path> i:<PID> Inject given BOF to a process with a given pid\n", .{});
    try stdout.print("info    <BOF>                       Display BOF description and usage examples\n", .{});
    try stdout.print("list    [TAG]                       List BOFs (all or based on provided TAG) from current collection\n", .{});
    try stdout.print("\nGeneral Options:\n\n", .{});
    try stdout.print("-h, --help      Print this help\n", .{});
    try stdout.print("-v, --version   Print version number\n\n", .{});
}

fn usageExec() !void {
    const stdout = io.getStdOut().writer();
    try stdout.print("\nExecute given BOF from filesystem with provided ARGUMENTs.\n\n", .{});
    try stdout.print("ARGUMENTS:\n\n", .{});
    try stdout.print("ARGUMENT's data type can be specified using one of following prefix:\n", .{});
    try stdout.print("  s:     - 16-bit signed integer.\n", .{});
    try stdout.print("  i:     - 32-bit signed integer.\n", .{});
    try stdout.print("  z:     - zero-terminated characters string.\n", .{});
    try stdout.print("  Z:     - zero-terminated wide characters string.\n", .{});
    try stdout.print("  file:  - special type followed by absolute file path indicating that a pointer to a buffer\n" ++
        "           filled with content of the file will be passed to BOF.\n", .{});
    try stdout.print(
        "\nIf prefix is ommited then ARGUMENT is treated as a zero-terminated characters string (str / z).\n",
        .{},
    );
    try stdout.print("\nEXAMPLES:\n\n", .{});
    try stdout.print("cli4bofs exec uname -a\n", .{});
    try stdout.print("cli4bofs exec udpScanner 192.168.2.2-10:427\n", .{});
    try stdout.print("cli4bofs exec udpScanner z:192.168.2.2-10:427\n", .{});
    try stdout.print("cli4bofs exec udpScanner 192.168.2.2-10:427 file:/path/to/file/with/udpPayloads\n\n", .{});
}

const has_injection_bof = switch (@import("builtin").os.tag) {
    .windows => switch (@import("builtin").cpu.arch) {
        .x86 => true,
        .x86_64 => true,
        else => unreachable,
    },
    .linux => switch (@import("builtin").cpu.arch) {
        .x86 => false,
        .x86_64 => false,
        .arm => false,
        .aarch64 => false,
        else => unreachable,
    },
    else => unreachable,
};

pub fn main() !u8 {
    const stderr = io.getStdErr().writer();
    const stdout = io.getStdOut().writer();

    ///////////////////////////////////////////////////////////
    // heap preparation
    ///////////////////////////////////////////////////////////
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    ///////////////////////////////////////////////////////////
    // 1. look for BOF-collection.yaml file in cwd
    // 2. parse it if available and store results in the ArrayList
    ///////////////////////////////////////////////////////////
    const bofs_collection, const yaml_file = blk: {
        const file = std.fs.cwd().openFile("BOF-collection.yaml", .{}) catch {
            break :blk .{ @as([*]BofRecord, undefined)[0..0], null };
        };
        defer file.close();

        const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
        defer allocator.free(source);

        var yaml_file: yaml.Yaml = .{ .source = source };
        errdefer yaml_file.deinit(allocator);
        try yaml_file.load(allocator);

        const bofs_collection = try yaml_file.parse(arena_allocator, []BofRecord);

        break :blk .{ bofs_collection, yaml_file };
    };
    defer if (yaml_file) |yf| @constCast(&yf).*.deinit(allocator);

    ///////////////////////////////////////////////////////////
    // commands processing:
    // exec <BOF>: opening and launching BOF file
    // info <BOF>: dispalying BOF description, usage and example invocations
    // general options:
    // -h / --help
    ///////////////////////////////////////////////////////////
    const Cmd = enum {
        inject,
        exec,
        info,
        list,
        help,
    };

    const cmd_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, cmd_args);

    const prog_name = cmd_args[0];

    if (cmd_args.len < 2) {
        try usage(prog_name);
        return 0;
    }
    const command_name = cmd_args[1];

    var cmd: Cmd = undefined;
    var bof_name: [:0]const u8 = undefined;
    var bof_path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;

    var list_tag: []u8 = undefined;
    var list_by_tag: bool = false;

    if (mem.eql(u8, "-h", command_name) or mem.eql(u8, "--help", command_name)) {
        try usage(prog_name);
        return 0;
    } else if (mem.eql(u8, "-v", command_name) or mem.eql(u8, "--version", command_name)) {
        try stdout.print("{any}\n", .{version});
        return 0;
    } else if (mem.eql(u8, "list", command_name)) {
        cmd = .list;

        if (cmd_args.len > 2) {
            list_by_tag = true;
            list_tag = cmd_args[2];
        }
    } else if (mem.eql(u8, "inject", command_name)) {
        cmd = .inject;

        if (!has_injection_bof) {
            try stderr.writeAll("Command is not implemented for this platform. Aborting.\n");
            return 1;
        }
        if (cmd_args.len < 4) {
            try stderr.writeAll("Not enough arguments provided ('file:absolute_path_to_bof i:<pid>' required). Aborting.\n");
            return 1;
        }
        if (mem.indexOf(u8, cmd_args[2], "file:") == null) {
            try stderr.writeAll("First argument must be: 'file:absolute_path_to_bof'. Aborting.\n");
            return 1;
        }
    } else if (mem.eql(u8, "exec", command_name)) {
        cmd = .exec;
        if (cmd_args.len < 3) {
            try stderr.writeAll("No BOF provided. Aborting.\n");
            return 1;
        }
        bof_name = cmd_args[2];

        const absolute_bof_path = std.fs.cwd().realpathZ(bof_name, bof_path_buffer[0..]) catch {
            try stderr.writeAll("BOF not found. Aborting.\n");
            return 1;
        };
        bof_path_buffer[absolute_bof_path.len] = 0;
    } else if (mem.eql(u8, "info", command_name)) {
        cmd = .info;
        if (cmd_args.len < 3) {
            try stderr.writeAll("No BOF name provided. Aborting.\n");
            return 1;
        }
        bof_name = cmd_args[2];
    } else if (mem.eql(u8, "help", command_name)) {
        cmd = .help;
        if (cmd_args.len < 3) {
            try stderr.writeAll("No command name provided. Aborting.\n");
            return 1;
        }
    } else {
        try stderr.writeAll("Fatal: unrecognized command provided. Aborting.\n");
        return 1;
    }

    ///////////////////////////////////////////////////////////
    // initializing bof-launcher
    ///////////////////////////////////////////////////////////
    try bofs.initLauncher();
    defer bofs.releaseLauncher();

    switch (cmd) {
        .inject => {
            if (!has_injection_bof) unreachable;

            const bof_args = try bofs.Args.init();
            defer bof_args.release();

            var file_data: ?[]const u8 = null;
            defer if (file_data) |fd| allocator.free(fd);

            bof_args.begin();
            // start from BOF arguments
            for (cmd_args[2..]) |arg| {
                // handle case when file:<filepath> argument is provided
                if (mem.indexOf(u8, arg, "file:") != null) {
                    var iter = mem.tokenizeScalar(u8, arg, ':');

                    _ = iter.next() orelse return error.BadData;
                    const file_path = iter.next() orelse return error.BadData;

                    file_data = try loadFileContent(allocator, @ptrCast(file_path));

                    const len_str = try std.fmt.allocPrint(allocator, "i:{d}", .{file_data.?.len});
                    defer allocator.free(len_str);

                    try bof_args.add(len_str);
                    try bof_args.add(mem.asBytes(&file_data.?.ptr));

                    continue;
                }
                try bof_args.add(arg);
            }
            bof_args.end();

            const object = try bofs.Object.initFromMemory(@embedFile("injection_bof_embed"));
            defer object.release();

            const context = try object.run(bof_args.getBuffer());
            defer context.release();

            const exit_code = context.getExitCode();
            if (exit_code == 0) {
                try std.io.getStdOut().writer().print("Successfully injected BOF.\n", .{});
            } else {
                try std.io.getStdOut().writer().print("Failed to inject BOF. Invalid PID?\n", .{});
            }

            if (context.getOutput()) |output| {
                try std.io.getStdOut().writer().print("{s}", .{output});
            }
            return exit_code;
        },
        .exec => {
            ///////////////////////////////////////////////////////////
            // command line arguments processing: handling BOF arguments
            ///////////////////////////////////////////////////////////
            const bof_args = try bofs.Args.init();
            defer bof_args.release();

            var argv_iter = try std.process.argsWithAllocator(allocator);
            defer argv_iter.deinit();
            _ = argv_iter.skip(); // skip prog name
            _ = argv_iter.skip(); // skip command name
            _ = argv_iter.skip(); // skip BOF name

            // conduct parameter validation if BofRecord for given BOF exists in BOF-collection.yaml file
            const bof_doc = for (bofs_collection) |b| {
                if (std.mem.eql(u8, bof_name, b.name)) {
                    break b;
                }
            } else null;

            if (bof_doc != null) {
                if (bof_doc.?.arguments) |arguments| for (arguments) |doc_arg| {
                    const cmd_arg = argv_iter.next();
                    if (cmd_arg) |a| {
                        // verify if argument's type is correct:
                        if (!checkArgType(a, doc_arg.type)) {
                            try stdout.print(
                                "Wrong argument type provided. BOF argument: '{s}' should be of type: '{s}'. Aborting.\n",
                                .{ doc_arg.name, doc_arg.type },
                            );
                            return 1;
                        }

                        // complain if the argument wasn't provided but it is required:
                    } else if (std.mem.eql(u8, doc_arg.required, "true")) {
                        try stdout.print(
                            "BOF user argument: '{s}' is required! Aborting.\n",
                            .{doc_arg.name},
                        );
                        return 1;
                    }
                };
            }

            var file_data: ?[]const u8 = null;
            defer if (file_data) |fd| allocator.free(fd);

            bof_args.begin();
            // start from BOF arguments
            for (cmd_args[3..]) |arg| {
                // handle case when file:<filepath> argument is provided
                if (mem.indexOf(u8, arg, "file:") != null) {
                    var iter = mem.tokenizeScalar(u8, arg, ':');

                    _ = iter.next() orelse return error.BadData;
                    const file_path = iter.next() orelse return error.BadData;

                    file_data = try loadFileContent(allocator, @ptrCast(file_path));

                    const len_str = try std.fmt.allocPrint(allocator, "i:{d}", .{file_data.?.len});
                    defer allocator.free(len_str);

                    try bof_args.add(len_str);
                    try bof_args.add(mem.asBytes(&file_data.?.ptr));

                    continue;
                }
                try bof_args.add(arg);
            }
            bof_args.end();

            ///////////////////////////////////////////////////////////
            // run selected BOF with provided arguments
            ///////////////////////////////////////////////////////////
            const result = try runBofFromFile(
                allocator,
                &bof_path_buffer,
                bof_args.getBuffer(),
            );

            return result;
        },
        .info => {
            for (bofs_collection) |bof| {
                if (std.mem.eql(u8, bof_name, bof.name)) {
                    try stdout.print("Name: {s}\n", .{bof.name});
                    try stdout.print("Description: {s}\n", .{bof.description});
                    try stdout.print("BOF authors(s): {s}\n", .{bof.author});

                    // display BOF entrypoint function ( go() ) if it exists
                    try stdout.print("\nENTRYPOINT:\n\n", .{});
                    if (bof.entrypoint) |entryp| {
                        try stdout.print("{s}()\n", .{entryp});
                        try stdout.print("\nARGUMENTS:\n\n", .{});
                        for (bof.arguments.?) |arg| {
                            if (arg.api == null) {
                                var column1: []u8 = undefined;
                                if (std.mem.eql(u8, arg.required, "false")) {
                                    column1 = try std.fmt.allocPrint(
                                        allocator,
                                        "[ {s}:{s} ]",
                                        .{ arg.type, arg.name },
                                    );
                                } else column1 = try std.fmt.allocPrint(
                                    allocator,
                                    "{s}:{s}",
                                    .{ arg.type, arg.name },
                                );
                                defer allocator.free(column1);
                                try stdout.print("{s:<32}", .{column1});
                                try stdout.print("{s}\n", .{arg.desc});
                            }
                        }
                    } else try stdout.print("None\n", .{});

                    // display API function signatures exposed by a BOF if any
                    if (bof.api != null) {
                        try stdout.print("\nAPI:\n\n", .{});
                        for (bof.api.?) |api_entry| {
                            try stdout.print("{s}\n", .{api_entry});
                        }

                        for (bof.api.?) |entryp| {
                            var iter = std.mem.tokenizeScalar(u8, entryp, '(');
                            const funcName = iter.next() orelse return error.BadData;

                            try stdout.print("\nARGUMENTS: {s}()\n\n", .{funcName});
                            for (bof.arguments.?) |arg| {
                                if (std.mem.eql(u8, arg.api.?, funcName)) {
                                    if (std.mem.eql(u8, arg.required, "false")) try stdout.print("[ ", .{});
                                    try stdout.print("{s:<32}", .{arg.name});
                                    if (std.mem.eql(u8, arg.required, "false")) try stdout.print(" ]", .{});
                                    try stdout.print("{s}\n", .{arg.desc});
                                }
                            }
                        }
                    }

                    // dsiplay error codes and their meaning returned by a BOF
                    try stdout.print("\nPOSSIBLE ERRORS:\n\n", .{});
                    if (bof.errors) |errors| for (errors) |err| {
                        try stdout.print("{s} ({x}) : {s}\n", .{ err.name, err.code, err.message });
                    };

                    try stdout.print("\nEXAMPLES: {s}\n", .{bof.examples});
                }
            }
        },
        .list => {
            var platform: []u8 = undefined;

            if (list_by_tag)
                try stdout.print("BOFs with '{s}' tag:\n", .{list_tag});

            for (bofs_collection) |bof| {
                if (std.mem.eql(u8, bof.OS, "windows")) {
                    platform = try std.fmt.allocPrint(allocator, "windows", .{});
                } else if (std.mem.eql(u8, bof.OS, "linux")) {
                    platform = try std.fmt.allocPrint(allocator, "linux", .{});
                } else platform = try std.fmt.allocPrint(allocator, "windows,linux", .{});

                if (list_by_tag) {
                    for (bof.tags) |tag| {
                        if (std.mem.eql(u8, tag, list_tag))
                            try stdout.print("{s:<16} | {s:<13} | {s}\n", .{ bof.name, platform, bof.description });
                    }
                } else try stdout.print("{s:<16} | {s:<13} | {s}\n", .{ bof.name, platform, bof.description });

                defer allocator.free(platform);
            }
        },
        .help => {
            const cmd_help = cmd_args[2];

            if (std.mem.eql(u8, cmd_help, "exec")) {
                try usageExec();
            } else if (std.mem.eql(u8, cmd_help, "info")) {
                try stdout.print("info <BOF>  - Display BOF description and usage examples\n", .{});
            } else if (std.mem.eql(u8, cmd_help, "list")) {
                try stdout.print("list [TAG]  - List BOFs (all or based on TAG) from BOF-collection.yaml file\n", .{});
            } else if (std.mem.eql(u8, cmd_help, "help")) {
                try stdout.print("help <COMMAND>  - Display help about given command\n", .{});
            } else {
                try stderr.writeAll("Fatal: unrecognized command provided. Aborting.\n");
            }
        },
    }

    return 0;
}
