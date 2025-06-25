const std = @import("std");
const builtin = @import("builtin");

const ProcessState = enum(i32) {
    const Self = @This();

    running,
    erroring,
    exited,
    not_started,

    inline fn handleProcessBehavior(self: Self) bool {
        return switch (self) {
            .running => true,
            .erroring => true,
            .exited => false,
            .not_started => true,
        };
    }
};

/// Custom wrapper for waitpid that properly handles errors instead of using unreachable
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
            .CHILD => return error.ProcessNotFound, // Process doesn't exist
            .INVAL => return error.InvalidArgument, // Invalid flags
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub const FileWatcher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    files: std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    command: []const []const u8,
    process: ?std.process.Child,
    process_state: std.atomic.Value(ProcessState),
    gitignore: std.ArrayList([]const u8),
    stdout_thread: ?std.Thread,
    stderr_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .command = command,
            .process = null,
            .process_state = std.atomic.Value(ProcessState).init(.not_started),
            .gitignore = try readGitIgnore(allocator),
            .stdout_thread = null,
            .stderr_thread = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Signal threads to exit by changing process state
        self.process_state.store(.exited, .seq_cst);

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

        // Wait for output threads to finish
        if (self.stdout_thread) |thread| {
            thread.join();
        }

        if (self.stderr_thread) |thread| {
            thread.join();
        }

        // Ensure we switch back to main screen
        std.io.getStdOut().writer().writeAll("\x1b[?1049l") catch {};
    }

    // Thread function to handle stdout stream
    fn outputHandler(self: *Self, stream: std.fs.File.Reader) void {
        const stdout = std.io.getStdOut().writer();
        var buf: [4096]u8 = undefined;

        while (true) {
            if (self.process_state.load(.seq_cst) != .running) {
                break;
            }

            const bytes_read = stream.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }

                // Log other errors but don't crash
                std.log.err("Error reading from process output: {s}", .{@errorName(err)});
                break;
            };

            if (bytes_read == 0) break;

            stdout.writeAll(buf[0..bytes_read]) catch |err| {
                std.log.err("Error writing to stdout: {s}", .{@errorName(err)});
                break;
            };
        }

        // clear the screen
        stdout.writeAll("\x1b[2J\x1b[H") catch {};
    }

    // Thread function to handle stderr stream
    fn errorHandler(self: *Self, stream: std.fs.File.Reader) void {
        const stdout = std.io.getStdErr().writer();
        var buf: [4096]u8 = undefined;

        while (self.process_state.load(.seq_cst) == .erroring) {
            std.debug.print("outputHandler {s}\n", .{@tagName(self.process_state.load(.seq_cst))});

            const bytes_read = stream.read(&buf) catch |err| {
                if (err == error.WouldBlock) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                }

                // Log other errors but don't crash
                std.log.err("Error reading from process error stream: {s}", .{@errorName(err)});
                break;
            };

            if (bytes_read == 0) break;

            // Write to stderr with a distinctive color
            // stdout.writeAll("\x1b[31m") catch {}; // Red text
            stdout.writeAll(buf[0..bytes_read]) catch |err| {
                std.log.err("Error writing to stderr: {s}", .{@errorName(err)});
                break;
            };
            // stdout.writeAll("\x1b[0m") catch {}; // Reset color
        }

        // clear the screen
        stdout.writeAll("\x1b[2J\x1b[H") catch {};
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

    fn isIgnored(self: *Self, path: []const u8) !bool {
        if (std.mem.startsWith(u8, path, try std.fs.path.join(self.allocator, &.{ ".", ".git/" }))) {
            return true;
        }

        const path_to_check = if (std.mem.startsWith(u8, path, "/"))
            path[1..]
        else
            path;

        const result = try std.process.Child.run(.{
            .argv = &.{ "git", "check-ignore", "-q", path_to_check },
            .allocator = self.allocator,
        });

        return result.term.Exited == 0;
    }

    fn scanFiles(self: *Self, dir_path: []const u8) !bool {
        var changes_detected = false;

        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(full_path);

            // Check if the path is ignored by git
            if (try self.isIgnored(full_path)) {
                continue;
            }

            switch (entry.kind) {
                .directory => {
                    // Recursively scan non-ignored directories
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
                            // Path already exists in our map with the same mtime
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
        // Signal threads to exit by changing process state
        self.process_state.store(.not_started, .seq_cst);

        if (self.process) |*process| {
            _ = try process.kill();

            // Wait for process to terminate
            _ = try process.wait();

            // Wait for output threads to finish
            if (self.stdout_thread) |thread| {
                thread.join();
            }

            if (self.stderr_thread) |thread| {
                thread.join();
            }

            self.stdout_thread = null;
            self.stderr_thread = null;
            self.process = null;
        }

        // Switch to alternate screen and clear it
        try std.io.getStdOut().writer().writeAll("\x1b[?1049h\x1b");
        try std.io.getStdOut().writer().writeAll("\x1b[2J\x1b[H");

        // Set state to running before spawning threads
        self.process_state.store(.running, .seq_cst);

        var process = std.process.Child.init(self.command, self.allocator);
        // Set up pipe for stdout and stderr
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe; // Capture stderr too

        try process.spawn();
        self.process = process;

        // Create thread to handle stdout
        self.stdout_thread = try std.Thread.spawn(
            .{},
            outputHandler,
            .{ self, process.stdout.?.reader() },
        );

        // Create thread to handle stderr
        self.stderr_thread = try std.Thread.spawn(
            .{},
            errorHandler,
            .{ self, process.stderr.?.reader() },
        );
    }

    fn handleProcessState(self: *Self) !bool {
        if (self.process) |*process| {
            const pid = process.id;
            const result = safeWaitpid(pid, 1) catch |err| {
                switch (err) {
                    error.ProcessNotFound => {
                        // Process no longer exists
                        std.log.info("Process not found", .{});
                        self.process = null;
                        self.process_state.store(.exited, .seq_cst);
                        return true; // Continue watching for file changes
                    },
                    error.InvalidArgument => {
                        std.log.err("Invalid argument to waitpid", .{});
                        self.process = null;
                        self.process_state.store(.erroring, .seq_cst);
                        return true; // Continue watching
                    },
                    else => {
                        std.log.err("Unexpected error in waitpid: {s}", .{@errorName(err)});
                        self.process = null;
                        self.process_state.store(.erroring, .seq_cst);
                        return true; // Continue watching
                    },
                }
            };

            if (result.pid != 0) {
                // Process has exited
                if (std.posix.W.IFEXITED(result.status)) {
                    const exit_code = std.posix.W.EXITSTATUS(result.status);
                    if (exit_code != 0) {
                        self.process_state.store(.erroring, .seq_cst);
                        std.log.err("{s} exited with error code: {d}", .{ self.command[0], exit_code });
                        return self.process_state.load(.seq_cst).handleProcessBehavior();
                    } else {
                        self.process_state.store(.exited, .seq_cst);
                        // Switch back to main screen before exiting
                        try std.io.getStdOut().writer().writeAll("\x1b[?1049l");
                        std.log.info("{s} completed successfully", .{self.command[0]});
                        return false; // Signal to exit the watch loop
                    }
                } else if (std.posix.W.IFSIGNALED(result.status)) {
                    // Process was terminated by a signal
                    self.process_state.store(.erroring, .seq_cst);
                    const signal = std.posix.W.TERMSIG(result.status);
                    std.log.err("{s} terminated by signal: {d}", .{ self.command[0], signal });
                    return self.process_state.load(.seq_cst).handleProcessBehavior();
                }

                self.process_state.store(.erroring, .seq_cst);

                // Clear the process reference since it's no longer running
                self.process = null;
            } else {
                // Process is still running
                self.process_state.store(.running, .seq_cst);
            }
        } else {
            self.process_state.store(.exited, .seq_cst);
        }

        return true; // Continue watching
    }

    pub fn watch(self: *Self) !void {
        // Initial scan
        _ = try self.scanFiles(".");

        // Start the process initially
        self.startProcess() catch |err| {
            self.process_state.store(.erroring, .seq_cst);
            std.log.err("Failed to start process: {s}, error: {s}", .{ self.command[0], @errorName(err) });
        };

        while (true) {
            std.debug.print("watch {s}\n", .{@tagName(self.process_state.load(.seq_cst))});
            // Handle the current process state and decide whether to continue
            const should_continue = try self.handleProcessState();
            if (!should_continue) {
                break;
            }

            std.time.sleep(500 * std.time.ns_per_ms); // 500ms poll interval

            const changes_detected = try self.scanFiles(".");

            if (changes_detected) {
                std.log.info("File changes detected or process not running, restarting process...", .{});
                self.startProcess() catch |err| {
                    self.process_state.store(.erroring, .seq_cst);
                    std.log.err("Failed to restart process: {s}, error: {s}", .{ self.command[0], @errorName(err) });
                };
            }
        }
    }
};
