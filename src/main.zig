const std = @import("std");

const FileWatcher = @import("file_watcher.zig").FileWatcher;

const version = "0.1.0";

fn printUsage(prog_name: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("Usage: {s} <command> [args...]\n", .{prog_name}) catch {};
    stdout.print("Example: {s} zig build run\n", .{prog_name}) catch {};
    stdout.print("Options:\n  -h, --help     Show this help message\n  -v, --version  Show version\n", .{}) catch {};
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get command from args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage(args[0]);
        return;
    }

    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
        printUsage(args[0]);
        return;
    }

    if (std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
        std.io.getStdOut().writer().print("wx {s}\n", .{version}) catch {};
        return;
    }

    const command = args[1..];

    var watcher = try FileWatcher.init(allocator, command);
    defer watcher.deinit();

    try watcher.watch();
}
