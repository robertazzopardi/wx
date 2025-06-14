//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("wx_lib");

const ChangeStore = std.StringHashMap(i128);
const ArrayList = std.ArrayList([]const u8);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();

    // try stdout.print("Run `zig build test` to run the tests.\n", .{});

    // try bw.flush(); // Don't forget to flush!

    // Read system args
    var command = ArrayList.init(allocator);
    defer command.deinit();
    var args = std.process.args();
    _ = args.skip();
    // while (args.next()) |arg| {
    //     // std.debug.print("{s}\n", .{arg});
    //     try command.append(arg);
    // }
    const str_cmd = args.next().?;
    var str_split = std.mem.splitSequence(u8, str_cmd, " ");
    while (str_split.next()) |part| {
        try command.append(part);
    }

    // Command runner
    const cmd: []const []const u8 = command.items;
    try runCommand(allocator, cmd);

    // Read the files
    //
    // var store = ChangeStore.init(allocator);
    // defer store.deinit();

    // const watch_dir = try std.fs.cwd().realpathAlloc(allocator, ".");

    // var watch_iter = try std.fs.openDirAbsolute(
    //     watch_dir,
    //     .{ .iterate = true },
    // );
    // defer watch_iter.close();

    // var dir_walker: std.fs.Dir.Walker = undefined;
    // defer dir_walker.deinit();

    // var first_check = true;

    // while (true) {
    //     dir_walker = try watch_iter.walk(allocator);

    //     const m = try getDirModifications(
    //         allocator,
    //         watch_iter,
    //         &dir_walker,
    //         &store,
    //         &first_check,
    //     );
    //     std.debug.print("{}\n", .{m});

    //     std.time.sleep(1_000_000_000);
    // }
}

fn getDirModifications(
    allocator: std.mem.Allocator,
    watch_dir: std.fs.Dir,
    dir_walker: *std.fs.Dir.Walker,
    store: *ChangeStore,
    first_check: *bool,
) !bool {
    while (try dir_walker.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const file_stat = try watch_dir.statFile(entry.path);

        if (store.get(entry.path)) |prev_file_stat| {
            if (file_stat.mtime != prev_file_stat) {
                try store.put(entry.path, file_stat.mtime);
                return true;
            }
        } else {
            const copy_path = try allocator.dupe(u8, entry.path);
            try store.put(copy_path, file_stat.mtime);

            if (first_check.* == true) {
                continue;
            }

            return true;
        }
    }

    first_check.* = false;

    return false;
}

fn runCommand(allocator: std.mem.Allocator, command: []const []const u8) !void {
    std.log.info("{s}\n", .{command});

    var child = std.process.Child.init(command, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Stream stdout line by line
    if (child.stdout) |stdout| {
        var buf_reader = std.io.bufferedReader(stdout.reader());
        var reader = buf_reader.reader();

        var line_buf: [1024]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(line_buf[0..], '\n')) |line| {
            std.debug.print("Output: {s}\n", .{line});
        }
    }

    // Get stderr
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    // defer allocator.free(stderr);

    // Wait for completion
    const term = try child.wait();

    std.debug.print("Output: {s}\n", .{stderr});
    std.debug.print("Exit: {}\n", .{term});
}
