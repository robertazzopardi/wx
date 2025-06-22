const std = @import("std");

pub const FileWatcher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    files: std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    command: []const []const u8,
    process: ?std.process.Child,
    gitignore: std.ArrayList([]const u8),
    stdout_thread: ?std.Thread,
    stderr_thread: ?std.Thread,
    should_exit: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, command: []const []const u8) !Self {
        return Self{
            .allocator = allocator,
            .files = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .command = command,
            .process = null,
            .gitignore = try readGitIgnore(allocator),
            .stdout_thread = null,
            .stderr_thread = null,
            .should_exit = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.should_exit.store(true, .seq_cst);

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

        while (!self.should_exit.load(.seq_cst)) {
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
    }

    // Thread function to handle stderr stream
    fn errorHandler(self: *Self, stream: std.fs.File.Reader) void {
        const stderr = std.io.getStdErr().writer();
        var buf: [4096]u8 = undefined;

        while (!self.should_exit.load(.seq_cst)) {
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
            stderr.writeAll("\x1b[31m") catch {}; // Red text
            stderr.writeAll(buf[0..bytes_read]) catch |err| {
                std.log.err("Error writing to stderr: {s}", .{@errorName(err)});
                break;
            };
            stderr.writeAll("\x1b[0m") catch {}; // Reset color
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
        if (self.process) |*process| {
            self.should_exit.store(true, .seq_cst);

            _ = process.kill() catch |err| {
                std.log.err("Failed to kill previous process: {s}", .{@errorName(err)});
                // Continue anyway
            };

            // Wait for process to terminate
            _ = process.wait() catch |err| {
                std.log.err("Error waiting for process to terminate: {s}", .{@errorName(err)});
                // Continue anyway
            };

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

        // Reset exit flag
        self.should_exit.store(false, .seq_cst);

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

    pub fn watch(self: *Self) !void {
        // Initial scan
        _ = try self.scanFiles(".");

        // Start the process initially
        self.startProcess() catch |err| {
            std.log.err("Failed to start process: {s}, error: {s}", .{self.command[0], @errorName(err)});
        };

        while (true) {
            std.time.sleep(500 * std.time.ns_per_ms); // 500ms poll interval

            const changes_detected = try self.scanFiles(".");
            
            // Check if we need to restart the process
            const should_restart = changes_detected or (self.process == null);
            
            if (should_restart) {
                std.log.info("File changes detected or process not running, restarting process...", .{});
                self.startProcess() catch |err| {
                    std.log.err("Failed to restart process: {s}, error: {s}", .{self.command[0], @errorName(err)});
                };
            }

            if (self.process) |*process| {
                const pid = process.id;
                const result = std.posix.waitpid(pid, 1);
                // WNOHANG (1) means don't block, if process is still running, result.status will be 0
                if (result.pid != 0) {
                    // Process has exited
                    if (std.posix.W.IFEXITED(result.status)) {
                        const exit_code = std.posix.W.EXITSTATUS(result.status);
                        if (exit_code != 0) {
                            std.log.err("{s} exited with error code: {d}", .{ self.command[0], exit_code });
                            // Don't exit the watcher, wait for file changes to restart
                        } else {
                            // Normal exit with status 0
                            // Switch back to main screen before exiting
                            try std.io.getStdOut().writer().writeAll("\x1b[?1049l");
                            std.log.info("{s} completed successfully", .{self.command[0]});
                            break;
                        }
                    } else if (std.posix.W.IFSIGNALED(result.status)) {
                        // Process was terminated by a signal
                        const signal = std.posix.W.TERMSIG(result.status);
                        std.log.err("{s} terminated by signal: {d}", .{ self.command[0], signal });
                        // Don't exit the watcher, wait for file changes to restart
                    }
                    
                    // Clear the process reference since it's no longer running
                    self.process = null;
                }
            }
        }
    }
};
