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

    pub fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .command = command,
            .process = null,
            .process_running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
            g_child_pid.store(0, .seq_cst);
        }

        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();

        leaveAlternateScreen();
    }

    /// Load patterns from a .gitignore file in dir_path. Returns an empty list if none exists.
    fn loadGitIgnore(allocator: std.mem.Allocator, dir_path: []const u8) std.ArrayList([]const u8) {
        var patterns = std.ArrayList([]const u8).init(allocator);
        const gitignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gitignore" }) catch return patterns;
        defer allocator.free(gitignore_path);

        const contents = std.fs.cwd().readFileAlloc(allocator, gitignore_path, 65536) catch return patterns;
        defer allocator.free(contents);

        var lines = std.mem.splitSequence(u8, contents, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            // Skip negation patterns (! prefix) — not supported
            if (trimmed[0] == '!') continue;
            patterns.append(allocator.dupe(u8, trimmed) catch continue) catch {};
        }

        return patterns;
    }

    fn matchesPattern(pattern: []const u8, name: []const u8, rel_path: []const u8) bool {
        // Directory-only pattern: "target/" — match the name without the trailing slash
        const p = if (std.mem.endsWith(u8, pattern, "/")) pattern[0 .. pattern.len - 1] else pattern;

        // Pattern with slash (other than trailing): anchored to the gitignore's dir.
        // e.g. "src/gen" only matches "src/gen", not "pkg/src/gen".
        if (std.mem.indexOfScalar(u8, p, '/') != null) {
            // Strip leading slash if present
            const anchored = if (p[0] == '/') p[1..] else p;
            return std.mem.eql(u8, rel_path, anchored) or
                std.mem.startsWith(u8, rel_path, anchored) and rel_path.len > anchored.len and rel_path[anchored.len] == '/';
        }

        // No slash: match against the entry name only (any depth).
        // Wildcard: "*.o", "*.zig-cache"
        if (std.mem.startsWith(u8, p, "*.")) {
            return std.mem.endsWith(u8, name, p[1..]);
        }
        // Plain glob with leading *: e.g. "*.log" already handled above; handle "*foo"
        if (p[0] == '*') {
            return std.mem.endsWith(u8, name, p[1..]);
        }

        // Exact name match
        return std.mem.eql(u8, name, p);
    }

    fn isIgnored(patterns: []const []const u8, name: []const u8, rel_path: []const u8) bool {
        for (patterns) |pattern| {
            if (matchesPattern(pattern, name, rel_path)) return true;
        }
        return false;
    }

    fn scanFiles(self: *Self, dir_path: []const u8) !bool {
        return self.scanDir(dir_path, ".");
    }

    fn scanDir(self: *Self, dir_path: []const u8, rel_base: []const u8) !bool {
        var changes_detected = false;

        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        // Load .gitignore for this directory
        const local_patterns = loadGitIgnore(self.allocator, dir_path);
        defer {
            for (local_patterns.items) |p| self.allocator.free(p);
            var lp = local_patterns;
            lp.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Always ignore .git
            if (std.mem.eql(u8, entry.name, ".git")) continue;

            // rel_path: path relative to this directory's .gitignore
            const rel_path = if (std.mem.eql(u8, rel_base, "."))
                try self.allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(self.allocator, &.{ rel_base, entry.name });
            defer self.allocator.free(rel_path);

            if (isIgnored(local_patterns.items, entry.name, rel_path)) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            switch (entry.kind) {
                .directory => {
                    if (try self.scanDir(full_path, rel_path)) {
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
                g_shutdown.store(true, .seq_cst);
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

            if (pending_restart) {
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
