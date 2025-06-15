const std = @import("std");
const lib = @import("wx_lib");
const xev = @import("xev");

const ChangeStore = std.StringHashMap(i128);
const ArrayList = std.ArrayList([]const u8);

const UserData = struct {
    const Self = @This();

    fs_changed: bool,
    async_watcher: *const xev.Async,
    command_manager: CommandManager,

    fn init(
        async_watcher: *const xev.Async,
        command_manager: CommandManager,
    ) Self {
        return Self{
            .fs_changed = false,
            .async_watcher = async_watcher,
            .command_manager = command_manager,
        };
    }
};

fn timerCallback(
    ud: ?*UserData,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    std.debug.print("timer\n", .{});

    if (ud) |data| {
        data.async_watcher.notify() catch |err| {
            std.debug.print("Failed to notify async: {}\n", .{err});
        };
    }

    return .disarm;
}

fn asyncCallback(
    ud: ?*UserData,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = result catch unreachable;
    std.debug.print("async\n", .{});

    if (ud) |data| {
        data.command_manager.start() catch unreachable;
    }

    return .disarm;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cmd = try extractCommand(allocator);
    const command = CommandManager.init(allocator, cmd);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var comp: xev.Completion = undefined;

    var as = try xev.Async.init();
    defer as.deinit();

    var data = UserData.init(&as, command);
    as.wait(&loop, &comp, UserData, &data, asyncCallback);

    var timer_comp: xev.Completion = undefined;
    const watcher = try xev.Timer.init();
    defer watcher.deinit();
    watcher.run(&loop, &timer_comp, 1, UserData, &data, timerCallback);

    try loop.run(.until_done);

    // Run the command

    // const cmd = try extractCommand(allocator);

    // var command = CommandManager.init(allocator, cmd);
    // try command.start();

    // Read the files

    var store = ChangeStore.init(allocator);
    defer store.deinit();

    const watch_dir = try std.fs.cwd().realpathAlloc(allocator, ".");

    var watch_iter = try std.fs.openDirAbsolute(
        watch_dir,
        .{ .iterate = true },
    );
    defer watch_iter.close();

    var dir_walker: std.fs.Dir.Walker = undefined;
    defer dir_walker.deinit();

    var first_check = true;

    while (true) {
        dir_walker = try watch_iter.walk(allocator);

        const files_changed = try getDirModifications(
            allocator,
            watch_iter,
            &dir_walker,
            &store,
            &first_check,
        );

        if (files_changed) {}

        std.time.sleep(1_000_000_000);
    }
}

fn extractCommand(allocator: std.mem.Allocator) !Command {
    var command = ArrayList.init(allocator);
    defer command.deinit();

    var args = std.process.args();
    _ = args.skip(); // first arg is the this programs value

    // process raw args
    while (args.next()) |arg| {
        // std.debug.print("{s}\n", .{arg});
        try command.append(arg);
    }

    // process args as a string
    // const str_cmd = args.next().?;
    // var str_split = std.mem.splitSequence(u8, str_cmd, " ");
    // while (str_split.next()) |part| {
    //     try command.append(part);
    // }

    return allocator.dupe([]const u8, command.items);
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

// fn runCommand(allocator: std.mem.Allocator, command: Command) !void {
//     std.log.info("{s}\n", .{command});

//     // Wait for completion
//     const term = try child.wait();

//     std.debug.print("Output: {s}\n", .{stderr});
//     std.debug.print("Exit: {}\n", .{term});
// }

const Command = []const []const u8;

const CommandManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    child: std.process.Child,

    fn init(allocator: std.mem.Allocator, command: Command) Self {
        var child = std.process.Child.init(command, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        return Self{ .child = child, .allocator = allocator };
    }

    fn start(self: *Self) !void {
        try self.child.spawn();

        try self.processOutput();
    }

    fn stop(self: Self) !void {
        try self.child.kill();
    }

    fn processOutput(self: Self) !void {
        if (self.child.stdout) |stdout| {
            var buf_reader = std.io.bufferedReader(stdout.reader());
            var reader = buf_reader.reader();

            var line_buf: [1024]u8 = undefined;
            while (try reader.readUntilDelimiterOrEof(line_buf[0..], '\n')) |line| {
                std.debug.print("{s}\n", .{line});
            }
        }

        // Get stderr
        const stderr = try self.child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);
    }
};
