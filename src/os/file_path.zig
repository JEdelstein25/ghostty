const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.file_path);

/// Information about a parsed file path
pub const FileLocation = struct {
    path: []const u8,
    line: ?usize = null,
    column: ?usize = null,

    pub fn deinit(self: FileLocation, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

/// Parse a potential file path with optional line:column numbers
/// Formats supported:
/// - path/to/file.ext
/// - path/to/file.ext:123
/// - path/to/file.ext:123:45
pub fn parseFilePath(
    alloc: Allocator,
    text: []const u8,
) !?FileLocation {
    // Skip if it looks like a URL with a scheme
    if (std.mem.indexOf(u8, text, "://")) |_| return null;

    var path = text;
    var line: ?usize = null;
    var column: ?usize = null;

    // Parse from the end: find :column or :line:column
    if (std.mem.lastIndexOf(u8, path, ":")) |last_colon_idx| {
        const after_last_colon = path[last_colon_idx + 1 ..];

        // Try to parse as number
        if (std.fmt.parseUnsigned(usize, after_last_colon, 10)) |num| {
            path = path[0..last_colon_idx];

            // Check if there's another number before this one
            if (std.mem.lastIndexOf(u8, path, ":")) |prev_colon_idx| {
                const after_prev_colon = path[prev_colon_idx + 1 ..];

                if (std.fmt.parseUnsigned(usize, after_prev_colon, 10)) |line_num| {
                    // We have line:column
                    line = line_num;
                    column = num;
                    path = path[0..prev_colon_idx];
                } else |_| {
                    // Only the last number is valid, it's a line number
                    line = num;
                }
            } else {
                // Only one number, it's a line number
                line = num;
            }
        } else |_| {
            // Not a number, keep as part of path
        }
    }

    // Trim any trailing/leading whitespace
    path = std.mem.trim(u8, path, " \t\r\n");

    if (path.len == 0) return null;

    return FileLocation{
        .path = try alloc.dupe(u8, path),
        .line = line,
        .column = column,
    };
}

/// Validate that a file path exists and resolve it to an absolute path
pub fn validateAndResolve(
    alloc: Allocator,
    file_loc: FileLocation,
    pwd: ?[]const u8,
) !?FileLocation {
    var absolute_path: []const u8 = undefined;
    var path_owned = false;

    // Expand ~ to home directory
    if (file_loc.path.len > 0 and file_loc.path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return null;
        const rel_path = if (file_loc.path.len > 1 and file_loc.path[1] == '/')
            file_loc.path[2..]
        else
            file_loc.path[1..];

        absolute_path = try std.fs.path.join(alloc, &.{ home, rel_path });
        path_owned = true;
    } else if (std.fs.path.isAbsolute(file_loc.path)) {
        absolute_path = file_loc.path;
    } else if (pwd) |p| {
        absolute_path = try std.fs.path.join(alloc, &.{ p, file_loc.path });
        path_owned = true;
    } else {
        return null;
    }
    defer if (path_owned) alloc.free(absolute_path);

    // Check if file exists using statFile
    const file = std.fs.cwd().statFile(absolute_path) catch return null;

    // Only allow regular files, not directories
    if (file.kind != .file) return null;

    // Resolve to canonical path
    const canonical = std.fs.cwd().realpathAlloc(alloc, absolute_path) catch {
        // If realpath fails, just use the absolute path
        return FileLocation{
            .path = try alloc.dupe(u8, absolute_path),
            .line = file_loc.line,
            .column = file_loc.column,
        };
    };

    return FileLocation{
        .path = canonical,
        .line = file_loc.line,
        .column = file_loc.column,
    };
}

test "parseFilePath basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Basic path
    {
        const result = try parseFilePath(alloc, "src/main.zig");
        try testing.expect(result != null);
        defer result.?.deinit(alloc);
        try testing.expectEqualStrings("src/main.zig", result.?.path);
        try testing.expectEqual(@as(?usize, null), result.?.line);
        try testing.expectEqual(@as(?usize, null), result.?.column);
    }

    // Path with line number
    {
        const result = try parseFilePath(alloc, "src/main.zig:47");
        try testing.expect(result != null);
        defer result.?.deinit(alloc);
        try testing.expectEqualStrings("src/main.zig", result.?.path);
        try testing.expectEqual(@as(?usize, 47), result.?.line);
        try testing.expectEqual(@as(?usize, null), result.?.column);
    }

    // Path with line and column
    {
        const result = try parseFilePath(alloc, "src/main.zig:47:20");
        try testing.expect(result != null);
        defer result.?.deinit(alloc);
        try testing.expectEqualStrings("src/main.zig", result.?.path);
        try testing.expectEqual(@as(?usize, 47), result.?.line);
        try testing.expectEqual(@as(?usize, 20), result.?.column);
    }

    // URL should be rejected
    {
        const result = try parseFilePath(alloc, "https://example.com:8080/path");
        try testing.expectEqual(@as(?FileLocation, null), result);
    }

    // Path with whitespace
    {
        const result = try parseFilePath(alloc, "  src/main.zig:47  ");
        try testing.expect(result != null);
        defer result.?.deinit(alloc);
        try testing.expectEqualStrings("src/main.zig", result.?.path);
        try testing.expectEqual(@as(?usize, 47), result.?.line);
    }
}
