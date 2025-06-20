const std = @import("std");

const FileWatcher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    files: std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    command: []const []const u8,
    process: ?std.process.Child,
    gitignore: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .command = command,
            .process = null,
            .gitignore = try readGitIgnore(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.gitignore.deinit();

        // Clean up file paths
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();

        if (self.process) |*process| {
            _ = process.kill() catch {};
        }
    }

    fn readGitIgnore(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        const fileContents = try std.fs.cwd().readFileAlloc(allocator, ".gitignore", 4096);
        defer allocator.free(fileContents);

        var gitignore = std.ArrayList([]const u8).init(allocator);

        var lines = std.mem.splitSequence(u8, fileContents, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            try gitignore.append(try allocator.dupe(u8, trimmed));
        }

        return gitignore;
    }

    fn scanFiles(self: *Self, dir_path: []const u8) !bool {
        var changes_detected = false;

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            switch (err) {
                error.FileNotFound => return false,
                else => return err,
            }
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            // // Only watch .zig files
            // if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

            const stat = dir.statFile(entry.path) catch continue;
            const owned_path = try self.allocator.dupe(u8, entry.path);

            if (self.files.get(entry.path)) |prev_mtime| {
                if (stat.mtime != prev_mtime) {
                    std.debug.print("Changed: {s}\n", .{entry.path});
                    try self.files.put(owned_path, stat.mtime);
                    changes_detected = true;
                }
            } else {
                try self.files.put(owned_path, stat.mtime);
                // Don't count initial scan as changes
            }
        }

        return changes_detected;
    }

    fn startProcess(self: *Self) !void {
        if (self.process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
        }

        var process = std.process.Child.init(self.command, self.allocator);
        process.stdout_behavior = .Inherit;
        process.stderr_behavior = .Inherit;

        try process.spawn();
        self.process = process;

        std.debug.print("Started process: {s}\n", .{self.command});
    }

    fn watch(self: *Self) !void {
        // Initial scan
        _ = try self.scanFiles(".");

        // Start the process initially
        try self.startProcess();

        std.debug.print("Watching for changes...\n", .{});

        while (true) {
            std.time.sleep(500 * std.time.ns_per_ms); // 500ms poll interval

            if (try self.scanFiles(".")) {
                std.debug.print("File changes detected, restarting...\n", .{});
                try self.startProcess();
            }

            if (self.process) |*process| {
                // std.debug.print("{any}\n", .{process.});

                const pid = process.id;
                const result = std.posix.waitpid(pid, 1);
                if (result.status == 0) {
                    std.log.info("{s} exited with status: {x}\n", .{ self.command, result.status });
                    break;
                }
            }
        }
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get command from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <command> [args...]\n", .{args[0]});
        std.debug.print("Example: {s} zig build run\n", .{args[0]});
        return;
    }

    const command = args[1..];

    var watcher = try FileWatcher.init(allocator, command);
    defer watcher.deinit();

    try watcher.watch();
}
