const std = @import("std");
const bofs = @import("bof-launcher");
const yaml = @import("yaml");

pub const std_options = .{
    .log_level = .info,
};

const io = std.io;
const mem = std.mem;

const BofRecord = struct {
    name: []const u8,
    description: []const u8,
    author: []const u8,
    tags: []const []const u8,
    OS: []const u8,
    header: ?[]const []const u8,
    execution_hint: ?[]const u8,
    entrypoints: ?[]const []const u8,
    sources: []const []const u8,
    usage: []const u8,
    examples: []const u8,
    arguments: ?[]const struct {
        name: []const u8,
        desc: []const u8,
        type: []const u8,
        required: []const u8,
        entrypoint: ?[]const u8,
    },
    errors: ?[]const struct {
        name: []const u8,
        code: u8,
        message: []const u8,
    },
};

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
) ![]u8 {
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
    try stdout.print("Usage: {s} command [options]\n\n", .{name});
    try stdout.print("Commands:\n\n", .{});
    try stdout.print("help     \tCOMMAND\t\tDisplay help about given command\n", .{});
    try stdout.print("exec     \tBOF\t\tExecute given BOF from a filesystem\n", .{});
    try stdout.print("info     \tBOF\t\tDisplay BOF description and usage examples\n", .{});
    try stdout.print("usage    \tBOF\t\tSee BOF usage details and parameter types\n", .{});
    try stdout.print("examples \tBOF\t\tSee the BOF usage examples\n", .{});
    try stdout.print("\nGeneral Options:\n\n", .{});
    try stdout.print("-c, --collection\t\tProvide custom BOF yaml collection\n", .{});
    try stdout.print("-h, --help\t\t\tPrint this help\n", .{});
}

fn usageExec() !void {
    const stdout = io.getStdOut().writer();
    try stdout.print("Execute given BOF from filesystem with provided ARGUMENTs.\n\n", .{});
    try stdout.print("ARGUMENTS:\n\n", .{});
    try stdout.print("ARGUMENT's data type can be specified using one of following prefix:\n", .{});
    try stdout.print("\tshort OR s\t - 16-bit signed integer.\n", .{});
    try stdout.print("\tint OR i\t - 32-bit signed integer.\n", .{});
    try stdout.print("\tstr OR z\t - zero-terminated characters string.\n", .{});
    try stdout.print("\twstr OR Z\t - zero-terminated wide characters string.\n", .{});
    try stdout.print(
        "\tfile OR b\t - special type followed by file path indicating that a pointer to a buffer " ++
            "filled with content of the file will be passed to BOF.\n",
        .{},
    );
    try stdout.print(
        "\nIf prefix is ommited then ARGUMENT is treated as a zero-terminated characters string (str / z).\n",
        .{},
    );
    try stdout.print("\nEXAMPLES:\n\n", .{});
    try stdout.print("cli4bofs uname -a\n", .{});
    try stdout.print("cli4bofs udpScanner 192.168.2.2-10:427\n", .{});
    try stdout.print("cli4bofs udpScanner z:192.168.2.2-10:427\n", .{});
    try stdout.print("cli4bofs udpScanner 192.168.2.2-10:427 file:/path/to/file/with/udpPayloads\n", .{});
}

pub fn main() !u8 {
    const stderr = io.getStdErr().writer();
    const stdout = io.getStdOut().writer();

    ///////////////////////////////////////////////////////////
    // heap preparation
    ///////////////////////////////////////////////////////////
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

        var yaml_file = try yaml.Yaml.load(allocator, source);
        const bofs_collection = try yaml_file.parse([]BofRecord);

        break :blk .{ bofs_collection, yaml_file };
    };
    defer if (yaml_file) |yf| @constCast(&yf).*.deinit();

    ///////////////////////////////////////////////////////////
    // commands processing:
    // exec <BOF>: opening and launching BOF file
    // info <BOF>: dispalying BOF facts
    // usage <BOF>: dispalying BOF usage
    // general options:
    // -h / --help
    // -c / --collection - user-provided BOF-collection.yaml path
    ///////////////////////////////////////////////////////////
    const Cmd = enum {
        exec,
        info,
        usage,
        examples,
        list,
        help,
    };

    var cmd_args_iter = try std.process.argsWithAllocator(allocator);
    defer cmd_args_iter.deinit();

    const prog_name = cmd_args_iter.next() orelse unreachable;
    const command_name = cmd_args_iter.next() orelse {
        try usage(prog_name);
        return 0;
    };

    var cmd: Cmd = undefined;
    var bof_name: [:0]const u8 = undefined;
    var bof_path_buffer: [std.fs.MAX_PATH_BYTES:0]u8 = undefined;

    if (mem.eql(u8, "-h", command_name) or mem.eql(u8, "--help", command_name)) {
        try usage(prog_name);
        return 0;
    } else if (mem.eql(u8, "exec", command_name)) {
        cmd = .exec;
        bof_name = cmd_args_iter.next() orelse {
            try stderr.writeAll("No BOF provided. Aborting.\n");
            return 1;
        };

        const absolute_bof_path = std.fs.cwd().realpathZ(bof_name, bof_path_buffer[0..]) catch {
            try stderr.writeAll("BOF not found. Aborting.\n");
            return 1;
        };
        bof_path_buffer[absolute_bof_path.len] = 0;
    } else if (mem.eql(u8, "info", command_name)) {
        cmd = .info;
        bof_name = cmd_args_iter.next() orelse {
            try stderr.writeAll("No BOF name provided. Aborting.\n");
            return 1;
        };
    } else if (mem.eql(u8, "usage", command_name)) {
        cmd = .usage;
        bof_name = cmd_args_iter.next() orelse {
            try stderr.writeAll("No BOF name provided. Aborting.\n");
            return 1;
        };

        try stdout.print("Number of docs items: {d}\n\n", .{yaml_file.?.docs.items.len});
    } else if (mem.eql(u8, "examples", command_name)) {
        cmd = .examples;
        bof_name = cmd_args_iter.next() orelse {
            try stderr.writeAll("No BOF name provided. Aborting.\n");
            return 1;
        };
    } else if (mem.eql(u8, "list", command_name)) {
        cmd = .list;
    } else if (mem.eql(u8, "help", command_name)) {
        cmd = .help;
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
        .exec => {
            ///////////////////////////////////////////////////////////
            // command line arguments processing: handling BOF arguments
            ///////////////////////////////////////////////////////////
            const bof_args = try bofs.Args.init();
            defer bof_args.release();

            var file_data: ?[]u8 = null;
            defer if (file_data) |fd| allocator.free(fd);

            bof_args.begin();
            while (cmd_args_iter.next()) |arg| {
                // handle case when file:<filepath> argument is provided
                if (mem.indexOf(u8, arg, "file:") != null) {
                    var iter = mem.tokenize(u8, arg, ":");

                    _ = iter.next() orelse return error.BadData;
                    const file_path = iter.next() orelse return error.BadData;

                    // load file content and remove final '\n' character (if present)

                    file_data = try loadFileContent(allocator, @ptrCast(file_path));
                    const trimmed_file_data = mem.trimRight(u8, file_data.?, "\n");

                    const len_str = try std.fmt.allocPrint(allocator, "i:{d}", .{trimmed_file_data.len});
                    defer allocator.free(len_str);

                    try bof_args.add(len_str);
                    try bof_args.add(mem.asBytes(&trimmed_file_data.ptr));

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

            try stdout.print("BOF exit code: {d}\n", .{result});
        },
        .info => {
            for (bofs_collection) |bof| {
                if (std.mem.eql(u8, bof_name, bof.name)) {
                    try stdout.print("Name: {s}\n", .{bof.name});
                    try stdout.print("Description: {s}\n", .{bof.description});
                    try stdout.print("BOF authors(s): {s}\n", .{bof.author});
                    try stdout.print("\n\nUSAGE INFORMATION: {s}\n", .{bof.usage});
                    try stdout.print("\n\nEXAMPLES: {s}\n", .{bof.examples});
                }
            }
        },
        .usage => {
            for (bofs_collection) |bof| {
                if (std.mem.eql(u8, bof_name, bof.name)) {
                    try stdout.print("ARGUMENTS:\n\n", .{});
                    for (bof.arguments.?, 0..) |arg, i| {
                        _ = i;
        
                        if (std.mem.eql(u8, arg.required, "false")) try stdout.print("[ ", .{});
                        try stdout.print("{s}:{s}", .{arg.type, arg.name});
                        if (std.mem.eql(u8, arg.required, "false")) try stdout.print(" ]", .{});
                        try stdout.print("\t\t{s}\n", .{arg.desc});
                    }

                    try stdout.print("\nPOSSIBLE ERRORS:\n\n", .{});
                    for (bof.errors.?, 0..) |err, i| {
                        _ = i;
        
                        try stdout.print("{s} ({d}) : {s}\n", .{err.name, err.code, err.message});
                    }
                }
            }
        },
        .examples => {
            for (bofs_collection) |bof| {
                if (std.mem.eql(u8, bof_name, bof.name)) {
                    try stdout.print("Usage examples:\n{s}\n", .{bof.examples});
                }
            }
        },
        .list => {
            for (bofs_collection) |bof| {
                try stdout.print("{s}\n", .{bof.name});
            }
        },
        .help => {
            const cmd_help = cmd_args_iter.next() orelse return 1;

            if (std.mem.eql(u8, cmd_help, "exec")) {
                try usageExec();
            } else {
                try stderr.writeAll("Fatal: unrecognized command provided. Aborting.\n");
            }
        },
    }

    return 0;
}
