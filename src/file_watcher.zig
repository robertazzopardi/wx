const std = @import("std");
const builtin = @import("builtin");

// Global state for signal handlers (must be file-scope, not inside struct)
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

fn setupSignals() void {
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

/// Custom wrapper for waitpid that properly handles EINTR
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

fn enterAlternateScreen() void {
    std.io.getStdOut().writer().writeAll("\x1b[?1049h\x1b[2J\x1b[H") catch {};
}

fn leaveAlternateScreen() void {
    std.io.getStdOut().writer().writeAll("\x1b[?1049l") catch {};
}

pub const FileWatcher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    files: std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    command: []const []const u8,
    process: ?std.process.Child,
    process_running: bool,
    gitignore: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .command = command,
            .process = null,
            .process_running = false,
            .gitignore = readGitIgnore(allocator) catch std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
            g_child_pid.store(0, .seq_cst);
        }

        self.gitignore.deinit();

        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();

        leaveAlternateScreen();
    }

    fn readGitIgnore(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        const file_contents = try std.fs.cwd().readFileAlloc(allocator, ".gitignore", 65536);
        defer allocator.free(file_contents);

        var gitignore = std.ArrayList([]const u8).init(allocator);

        var lines = std.mem.splitSequence(u8, file_contents, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            try gitignore.append(try allocator.dupe(u8, trimmed));
        }

        return gitignore;
    }

    fn matchesPattern(pattern: []const u8, name: []const u8, full_path: []const u8) bool {
        // Directory pattern: "node_modules/" matches directory by name
        if (std.mem.endsWith(u8, pattern, "/")) {
            return std.mem.eql(u8, name, pattern[0 .. pattern.len - 1]);
        }
        // Wildcard extension: "*.o" or "*.zig-cache"
        if (std.mem.startsWith(u8, pattern, "*.")) {
            return std.mem.endsWith(u8, name, pattern[1..]);
        }
        // Exact name match or full path match
        return std.mem.eql(u8, name, pattern) or std.mem.eql(u8, full_path, pattern);
    }

    fn isIgnored(self: *Self, name: []const u8, full_path: []const u8) bool {
        if (std.mem.eql(u8, name, ".git")) return true;
        for (self.gitignore.items) |pattern| {
            if (matchesPattern(pattern, name, full_path)) return true;
        }
        return false;
    }

    fn scanFiles(self: *Self, dir_path: []const u8) !bool {
        var changes_detected = false;

        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            if (self.isIgnored(entry.name, full_path)) continue;

            switch (entry.kind) {
                .directory => {
                    if (try self.scanFiles(full_path)) {
                        changes_detected = true;
                    }
                },
                .file => {
                    const stat = dir.statFile(entry.name) catch continue;
                    const owned_path = try self.allocator.dupe(u8, full_path);

                    if (self.files.get(full_path)) |prev_mtime| {
                        if (stat.mtime != prev_mtime) {
                            try self.files.put(owned_path, stat.mtime);
                            changes_detected = true;
                        } else {
                            self.allocator.free(owned_path);
                        }
                    } else {
                        try self.files.put(owned_path, stat.mtime);
                        // Don't count initial scan as changes
                    }
                },
                else => {},
            }
        }

        return changes_detected;
    }

    fn startProcess(self: *Self) !void {
        // Kill existing process if running
        if (self.process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
            self.process = null;
            self.process_running = false;
            g_child_pid.store(0, .seq_cst);
        }

        enterAlternateScreen();

        var process = std.process.Child.init(self.command, self.allocator);
        // Inherit all stdio so TUI apps get a real TTY
        process.stdin_behavior = .Inherit;
        process.stdout_behavior = .Inherit;
        process.stderr_behavior = .Inherit;

        try process.spawn();
        g_child_pid.store(process.id, .seq_cst);
        self.process = process;
        self.process_running = true;
    }

    fn checkProcess(self: *Self) !void {
        if (!self.process_running) return;

        const process = self.process orelse return;
        const result = safeWaitpid(process.id, 1) catch |err| {
            switch (err) {
                error.ProcessNotFound => {
                    self.process = null;
                    self.process_running = false;
                    g_child_pid.store(0, .seq_cst);
                },
                else => {
                    std.log.err("waitpid error: {s}", .{@errorName(err)});
                    self.process = null;
                    self.process_running = false;
                    g_child_pid.store(0, .seq_cst);
                },
            }
            return;
        };

        if (result.pid == 0) return; // still running

        // Process exited
        self.process = null;
        self.process_running = false;
        g_child_pid.store(0, .seq_cst);

        if (std.posix.W.IFEXITED(result.status)) {
            const code = std.posix.W.EXITSTATUS(result.status);
            if (code != 0) {
                std.log.err("{s} exited with code {d}", .{ self.command[0], code });
            } else {
                std.log.info("{s} exited successfully", .{self.command[0]});
            }
        } else if (std.posix.W.IFSIGNALED(result.status)) {
            const sig = std.posix.W.TERMSIG(result.status);
            // Ignore SIGTERM/SIGKILL — these are expected when wx restarts the process
            if (sig != std.posix.SIG.TERM and sig != std.posix.SIG.KILL) {
                std.log.err("{s} terminated by signal {d}", .{ self.command[0], sig });
            }
        }
    }

    pub fn watch(self: *Self) !void {
        setupSignals();

        // Initial scan (no changes counted)
        _ = try self.scanFiles(".");

        // Start the process initially
        self.startProcess() catch |err| {
            std.log.err("Failed to start {s}: {s}", .{ self.command[0], @errorName(err) });
        };

        var pending_restart = false;

        while (true) {
            if (g_shutdown.load(.seq_cst)) break;

            try self.checkProcess();

            std.time.sleep(150 * std.time.ns_per_ms);

            if (g_shutdown.load(.seq_cst)) break;

            const changes_detected = try self.scanFiles(".");
            if (changes_detected) pending_restart = true;

            // Only restart when the process is not running. This prevents the flicker
            // loop caused by build tools (cargo, zig, etc.) writing artifacts while
            // compiling — those file changes are noticed but held until the build exits.
            if (pending_restart and !self.process_running) {
                pending_restart = false;
                std.log.info("Changes detected, restarting...", .{});
                self.startProcess() catch |err| {
                    std.log.err("Failed to restart {s}: {s}", .{ self.command[0], @errorName(err) });
                };
            }
        }

        // Shutdown: kill child and restore terminal
        if (self.process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
            self.process = null;
            g_child_pid.store(0, .seq_cst);
        }
    }
};
