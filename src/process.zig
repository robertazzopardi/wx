const std = @import("std");
const builtin = @import("builtin");

var g_child_pid: std.atomic.Value(std.posix.pid_t) = .init(0);
var g_shutdown: std.atomic.Value(bool) = .init(false);

fn handleSigint(sig: i32) callconv(.c) void {
    _ = sig;
    g_shutdown.store(true, .seq_cst);
}

fn handleSigwinch(sig: i32) callconv(.c) void {
    _ = sig;
    const pid = g_child_pid.load(.seq_cst);
    if (pid > 0) _ = std.c.kill(pid, std.posix.SIG.WINCH);
}

pub fn setupSignals() void {
    const sa_int = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa_int, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa_int, null);

    const sa_winch = std.posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sa_winch, null);
}

pub fn isShutdownRequested() bool {
    return g_shutdown.load(.seq_cst);
}

fn clearScreen() void {
    std.io.getStdOut().writer().writeAll("\x1b[2J\x1b[H") catch {};
}

fn safeWaitpid(pid: std.posix.pid_t, flags: u32) !std.posix.WaitPidResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(pid, &status, @intCast(flags));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return .{
                .pid = @intCast(rc),
                .status = @bitCast(status),
            },
            .INTR => continue,
            .CHILD => return error.ProcessNotFound,
            .INVAL => return error.InvalidArgument,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub const CheckResult = enum { still_running, exited_ok, exited_error, exited_signal };

pub fn startChild(command: []const []const u8, allocator: std.mem.Allocator) !std.process.Child {
    clearScreen();
    var child = std.process.Child.init(command, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    g_child_pid.store(child.id, .seq_cst);
    return child;
}

pub fn stopChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
    _ = child.wait() catch {};
    g_child_pid.store(0, .seq_cst);
}

pub fn checkChild(child: std.process.Child, cmd_name: []const u8) !CheckResult {
    const result = safeWaitpid(child.id, 1) catch |err| {
        switch (err) {
            error.ProcessNotFound => {},
            else => std.log.err("waitpid error: {s}", .{@errorName(err)}),
        }
        g_child_pid.store(0, .seq_cst);
        return .exited_error;
    };

    if (result.pid == 0) return .still_running;

    g_child_pid.store(0, .seq_cst);

    if (std.posix.W.IFEXITED(result.status)) {
        const code = std.posix.W.EXITSTATUS(result.status);
        if (code != 0) {
            std.log.err("{s} exited with code {d}", .{ cmd_name, code });
            return .exited_error;
        } else {
            std.log.info("{s} exited successfully", .{cmd_name});
            g_shutdown.store(true, .seq_cst);
            return .exited_ok;
        }
    } else if (std.posix.W.IFSIGNALED(result.status)) {
        const sig = std.posix.W.TERMSIG(result.status);
        // Ignore SIGTERM/SIGKILL — these are expected when wx restarts the process
        if (sig != std.posix.SIG.TERM and sig != std.posix.SIG.KILL) {
            std.log.err("{s} terminated by signal {d}", .{ cmd_name, sig });
        }
        return .exited_signal;
    }

    return .exited_error;
}
