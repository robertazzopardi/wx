const std = @import("std");
const process = @import("process.zig");
const scanner = @import("scanner.zig");

/// Watches the current directory for file changes and restarts `command`
/// whenever a non-ignored file is created, modified, or its mtime changes.
pub const FileWatcher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    files: scanner.FileMap,
    command: []const []const u8,
    child: ?std.process.Child,

    /// Creates a watcher that will run `command` on changes.
    /// `command` must outlive the returned `FileWatcher`.
    pub fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = scanner.FileMap.init(allocator),
            .command = command,
            .child = null,
        };
    }

    /// Stops the child process (if running) and frees tracked file state.
    pub fn deinit(self: *Self) void {
        if (self.child) |*child| {
            process.stopChild(child);
            self.child = null;
        }

        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    /// Runs the watch loop: starts `command`, then restarts it whenever a
    /// tracked file changes, until a shutdown signal (SIGINT/SIGTERM) arrives.
    pub fn watch(self: *Self) !void {
        process.setupSignals();

        // Initial scan (no changes counted)
        _ = try scanner.scanFiles(&self.files, self.allocator, ".");

        // Start the process initially
        self.child = process.startChild(self.command, self.allocator) catch |err| blk: {
            std.log.err("Failed to start {s}: {s}", .{ self.command[0], @errorName(err) });
            break :blk null;
        };

        var pending_restart = false;

        while (true) {
            if (process.isShutdownRequested()) break;

            if (self.child) |child| {
                const result = try process.checkChild(child, self.command[0]);
                if (result != .still_running) {
                    self.child = null;
                    if (process.isShutdownRequested()) break;
                }
            }

            std.time.sleep(150 * std.time.ns_per_ms);

            if (process.isShutdownRequested()) break;

            const changes_detected = try scanner.scanFiles(&self.files, self.allocator, ".");
            if (changes_detected) pending_restart = true;

            if (pending_restart) {
                pending_restart = false;
                std.log.info("Changes detected, restarting...", .{});
                if (self.child) |*child| {
                    process.stopChild(child);
                    self.child = null;
                }
                self.child = process.startChild(self.command, self.allocator) catch |err| blk: {
                    std.log.err("Failed to restart {s}: {s}", .{ self.command[0], @errorName(err) });
                    break :blk null;
                };
            }
        }
    }
};
