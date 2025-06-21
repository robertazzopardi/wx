const std = @import("std");

const FileWatcher = @import("file_watcher.zig").FileWatcher;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get command from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.info("Usage: {s} <command> [args...]\n", .{args[0]});
        std.log.info("Example: {s} zig build run\n", .{args[0]});
        return;
    }

    const command = args[1..];

    var watcher = try FileWatcher.init(allocator, command);
    defer watcher.deinit();

    try watcher.watch();
}
