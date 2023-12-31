const std = @import("std");
const bofs = @import("bof-launcher");
const yaml = @import("yaml");

const io = std.io;
const mem = std.mem;

fn runBofFromFile(
    allocator: std.mem.Allocator,
    bof_path: [:0]const u8,
    arg_data: ?[]u8,
) !u8 {
    const file = std.fs.openFileAbsoluteZ(bof_path, .{}) catch unreachable;
    defer file.close();

    var file_data = std.ArrayListAligned(u8, 16).init(allocator);
    defer file_data.deinit();

    try file.reader().readAllArrayListAligned(16, &file_data, 16 * 1024 * 1024);

    const object = try bofs.Object.initFromMemory(file_data.items);
    defer object.release();

    const context = try object.runAsyncThread(arg_data, null, null);
    defer context.release();

    context.wait();

    if (context.getOutput()) |output| {
        try std.io.getStdOut().writer().print("{s}", .{output});
    }
    return context.getExitCode();
}

fn usage(name: [:0]const u8) void {
    const stdout = io.getStdOut().writer();
    stdout.print("Usage: {s} [command] [options]\n\n", .{name}) catch unreachable;
    stdout.print("Commands:\n\n", .{}) catch unreachable;
    stdout.print("exec\t\tExecute given BOF from filesystem\n", .{}) catch unreachable;
    stdout.print("info\t\tDisplay details about BOF\n", .{}) catch unreachable;
    stdout.print("\nGeneral Options:\n\n", .{}) catch unreachable;
    stdout.print("-c, --collection\tProvide custom BOF yaml collection\n", .{}) catch unreachable;
    stdout.print("-h, --help\t\tPrint this help\n", .{}) catch unreachable;
}

fn usageExec() void {
    const stdout = io.getStdOut().writer();
    stdout.print("Execute given BOF from filesystem with provided ARGUMENTs.\n\n", .{}) catch unreachable;
    stdout.print("ARGUMENTS:\n\n", .{}) catch unreachable;
    stdout.print("ARGUMENT's data type can be specified using one of following prefix:\n", .{}) catch unreachable;
    stdout.print("\tshort OR s\t - 16-bit signed integer.\n", .{}) catch unreachable;
    stdout.print("\tint OR i\t - 32-bit signed integer.\n", .{}) catch unreachable;
    stdout.print("\tstr OR z\t - zero-terminated characters string.\n", .{}) catch unreachable;
    stdout.print("\twstr OR Z\t - zero-terminated wide characters string.\n", .{}) catch unreachable;
    stdout.print("\tfile OR b\t - special type followed by file path indicating that a pointer to a buffer filled with content of the file will be passed to BOF.\n", .{}) catch unreachable;
    stdout.print("\nIf prefix is ommited then ARGUMENT is treated as a zero-terminated characters string (str / z).\n", .{}) catch unreachable;
    stdout.print("\nEXAMPLES:\n\n", .{}) catch unreachable;
    stdout.print("cli4bofs uname -a\n", .{}) catch unreachable;
    stdout.print("cli4bofs udpScanner 192.168.2.2-10:427\n", .{}) catch unreachable;
    stdout.print("cli4bofs udpScanner z:192.168.2.2-10:427\n", .{}) catch unreachable;
    stdout.print("cli4bofs udpScanner 192.168.2.2-10:427 file:/path/to/file/with/udpPayloads\n", .{}) catch unreachable;
}

pub fn loadBofCollection(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !void {
    const stderr = io.getStdErr().writer();
    if (file_path == null) {
        return stderr.writeAll("fatal: no input path to yaml file specified\n\n");
    }

    const file = try std.fs.cwd().openFile(file_path.?, .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));

    const stdout = io.getStdOut().writer();
    var parsed = try yaml.Yaml.load(allocator, source);
    try parsed.stringify(stdout);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

const Bof_record = struct {
    name: []const u8,
    description: []const u8,
    author: []const u8,
    tags: []const []const u8,
    OS: []const u8,
    header: []const []const u8,
    sources: []const []const u8,
    usage: []const u8,
    examples: []const []const u8,
};

pub fn main() !u8 {
    const stderr = io.getStdErr().writer();
    const stdout = io.getStdOut().writer();

    ///////////////////////////////////////////////////////////
    // heap preparation
    ///////////////////////////////////////////////////////////
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    ///////////////////////////////////////////////////////////
    // 1. look for BOF-collection.yaml file in cwd
    // 2. parse it if available and store results in the ArrayList
    ///////////////////////////////////////////////////////////
    const file = try std.fs.cwd().openFile("BOF-collection.yaml", .{});
    defer file.close();

    const source = try file.readToEndAlloc(allocator, std.math.maxInt(u32));

    var parsed = try yaml.Yaml.load(allocator, source);
    const bofs_collection = try parsed.parse([]Bof_record);

    ///////////////////////////////////////////////////////////
    // commands processing:
    // exec <BOF>: opening and launching BOF file
    // info <BOF>: dispalying BOF facts
    // usage <BOF>: dispalying BOF usage and examples
    // general options:
    // -h / --help
    // -c / --collection - user-provided BOF-collection.yaml path
    ///////////////////////////////////////////////////////////
    const Cmd = enum {
        none,
        exec,
        info,
        usage,
        list,
        help,
    };
    var cmd = Cmd.none;

    var cmd_args_iter = try std.process.argsWithAllocator(allocator);
    defer cmd_args_iter.deinit();

    const prog_name = cmd_args_iter.next() orelse unreachable;
    const command_name = cmd_args_iter.next() orelse {
        stderr.writeAll("No command or general option provided. Aborting.\n") catch unreachable;
        return 0;
    };

    var bof_name: [:0]const u8 = undefined;

    var bof_path_buffer: [std.fs.MAX_PATH_BYTES:0]u8 = undefined;

    if (mem.eql(u8, "-h", command_name) or mem.eql(u8, "--help", command_name)) {
        usage(prog_name);
    } else if (mem.eql(u8, "exec", command_name)) {
        cmd = Cmd.exec;
        bof_name = cmd_args_iter.next().?;

        const absolute_bof_path = std.fs.cwd().realpathZ(bof_name, bof_path_buffer[0..]) catch {
            stderr.writeAll("No BOF provided. Aborting.\n") catch unreachable;
            return 0;
        };
        bof_path_buffer[absolute_bof_path.len] = 0;
    } else if (mem.eql(u8, "info", command_name)) {
        cmd = Cmd.info;
        bof_name = cmd_args_iter.next().?;
    } else if (mem.eql(u8, "usage", command_name)) {
        cmd = Cmd.usage;
        bof_name = cmd_args_iter.next().?;
    } else if (mem.eql(u8, "list", command_name)) {
        cmd = Cmd.list;
    } else if (mem.eql(u8, "help", command_name)) {
        cmd = Cmd.help;
    } else {
        try stderr.writeAll("fatal: unrecognized command provided.\n");
    }

    ///////////////////////////////////////////////////////////
    // initializing bof-launcher
    ///////////////////////////////////////////////////////////
    try bofs.initLauncher();
    defer bofs.releaseLauncher();

    if (cmd == Cmd.exec) {
        stdout.print("Executing (BOF name): {any}\n", .{bof_name}) catch unreachable;
        ///////////////////////////////////////////////////////////
        // command line arguments processing: handling BOF arguments
        ///////////////////////////////////////////////////////////
        const bof_args = try bofs.Args.init();
        defer bof_args.release();

        bof_args.begin();
        while (cmd_args_iter.next()) |arg| {
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

        stdout.print("BOF exit code: {d}\n", .{result}) catch unreachable;
    } else if (cmd == Cmd.info) {
        for (bofs_collection) |bof| {
            if (std.mem.eql(u8, bof_name, bof.name)) {
                stdout.print("Name: {s}\n", .{bof.name}) catch unreachable;
                stdout.print("Description: {s}\n", .{bof.description}) catch unreachable;
            }
        }
    } else if (cmd == Cmd.usage) {
        for (bofs_collection) |bof| {
            if (std.mem.eql(u8, bof_name, bof.name)) {
                stdout.print("Usage:\n{s}\n", .{bof.usage}) catch unreachable;
            }
        }
    } else if (cmd == Cmd.list) {
        for (bofs_collection) |bof| {
            stdout.print("{s}\n", .{bof.name}) catch unreachable;
        }
    } else if (cmd == Cmd.help) {
        const cmd_help = cmd_args_iter.next().?;

        if (std.mem.eql(u8, cmd_help, "exec")) {
            usageExec();
        }
    }

    return 0;
}
