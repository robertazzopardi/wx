const std = @import("std");

pub const FileMap = std.HashMap([]const u8, i128, std.hash_map.StringContext, std.hash_map.default_max_load_percentage);

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

/// Recursively scans `dir_path`, updating `files` with current mtimes.
/// Returns `true` if any tracked file was added or changed since the last
/// scan (the very first scan of a file never counts as a change).
pub fn scanFiles(files: *FileMap, allocator: std.mem.Allocator, dir_path: []const u8) !bool {
    return scanDir(files, allocator, dir_path, ".");
}

/// Same as `scanFiles`, but for a subdirectory during recursion. `rel_base`
/// is the path of `dir_path` relative to the scan root, used to anchor
/// slash-containing `.gitignore` patterns.
pub fn scanDir(files: *FileMap, allocator: std.mem.Allocator, dir_path: []const u8, rel_base: []const u8) !bool {
    var changes_detected = false;

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    // Load .gitignore for this directory
    const local_patterns = loadGitIgnore(allocator, dir_path);
    defer {
        for (local_patterns.items) |p| allocator.free(p);
        var lp = local_patterns;
        lp.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Always ignore .git
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        // rel_path: path relative to this directory's .gitignore
        const rel_path = if (std.mem.eql(u8, rel_base, "."))
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_base, entry.name });
        defer allocator.free(rel_path);

        if (isIgnored(local_patterns.items, entry.name, rel_path)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                if (try scanDir(files, allocator, full_path, rel_path)) {
                    changes_detected = true;
                }
            },
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                const owned_path = try allocator.dupe(u8, full_path);

                if (files.get(full_path)) |prev_mtime| {
                    if (stat.mtime != prev_mtime) {
                        try files.put(owned_path, stat.mtime);
                        changes_detected = true;
                    } else {
                        allocator.free(owned_path);
                    }
                } else {
                    try files.put(owned_path, stat.mtime);
                    // Don't count initial scan as changes
                }
            },
            else => {},
        }
    }

    return changes_detected;
}

test "matchesPattern: extension wildcard" {
    try std.testing.expect(matchesPattern("*.o", "main.o", "main.o"));
    try std.testing.expect(!matchesPattern("*.o", "main.c", "main.c"));
}

test "matchesPattern: directory-only pattern" {
    try std.testing.expect(matchesPattern("zig-out/", "zig-out", "zig-out"));
}

test "matchesPattern: exact name match" {
    try std.testing.expect(matchesPattern(".DS_Store", ".DS_Store", ".DS_Store"));
    try std.testing.expect(!matchesPattern(".DS_Store", "DS_Store", "DS_Store"));
}

test "matchesPattern: anchored path with slash" {
    try std.testing.expect(matchesPattern("src/gen", "gen", "src/gen"));
    try std.testing.expect(!matchesPattern("src/gen", "gen", "pkg/src/gen"));
    try std.testing.expect(matchesPattern("src/gen", "gen", "src/gen/inner"));
}

test "isIgnored: matches any pattern in list" {
    const patterns = [_][]const u8{ "*.o", ".DS_Store" };
    try std.testing.expect(isIgnored(&patterns, "main.o", "main.o"));
    try std.testing.expect(isIgnored(&patterns, ".DS_Store", ".DS_Store"));
    try std.testing.expect(!isIgnored(&patterns, "main.zig", "main.zig"));
}
