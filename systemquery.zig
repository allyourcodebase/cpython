pub fn HeaderSet(comptime HeaderEnum: type) type {
    return struct {
        const Self = @This();
        bits: std.StaticBitSet(std.meta.fields(HeaderEnum).len),

        pub fn scanDirs(io: std.Io, include_dirs: []const []const u8) !Self {
            var set = Self{ .bits = std.StaticBitSet(std.meta.fields(HeaderEnum).len).initEmpty() };
            for (include_dirs) |include_dir| {
                try set.scanDir(io, include_dir, "");
            }
            return set;
        }

        pub fn contains(self: Self, header: HeaderEnum) bool {
            return self.bits.isSet(@intFromEnum(header));
        }

        const max_name_len = blk: {
            var max: usize = 0;
            for (std.meta.fields(HeaderEnum)) |field| {
                if (field.name.len > max) max = field.name.len;
            }
            break :blk max;
        };

        fn scanDir(self: *Self, io: std.Io, base_dir: []const u8, prefix: []const u8) !void {
            const sep: []const u8 = if (prefix.len == 0) "" else std.fs.path.sep_str;
            var dir = blk: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const dir_path = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ base_dir, sep, prefix }) catch return;
                break :blk std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound => return,
                    else => |e| return e,
                };
            };
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                var name_buf: [max_name_len]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "{s}{s}{s}", .{ prefix, sep, entry.name }) catch continue;
                if (entry.kind == .directory) {
                    if (headerPrefixExists(name)) try self.scanDir(io, base_dir, name);
                } else {
                    if (enumFromName(name)) |header| self.bits.set(@intFromEnum(header));
                }
            }
        }

        const known_prefixes = blk: {
            @setEvalBranchQuota(30 * std.meta.fields(HeaderEnum).len);
            var prefixes: []const []const u8 = &.{};
            for (std.meta.fields(HeaderEnum)) |field| {
                var start: usize = 0;
                while (std.mem.indexOfPos(u8, field.name, start, "/")) |sep_idx| {
                    const dir = field.name[0..sep_idx];
                    for (prefixes) |p| {
                        if (std.mem.eql(u8, p, dir)) break;
                    } else {
                        prefixes = prefixes ++ .{dir};
                    }
                    start = sep_idx + 1;
                }
            }
            break :blk prefixes;
        };

        fn eqlName(a: []const u8, b: []const u8) bool {
            return switch (builtin.os.tag) {
                .windows => std.ascii.eqlIgnoreCase(a, b),
                else => std.mem.eql(u8, a, b),
            };
        }

        fn enumFromName(name: []const u8) ?HeaderEnum {
            if (builtin.os.tag == .windows) {
                for (std.meta.fields(HeaderEnum), 0..) |field, i| {
                    if (std.ascii.eqlIgnoreCase(name, field.name))
                        return @enumFromInt(i);
                }
                return null;
            } else return std.meta.stringToEnum(HeaderEnum, name);
        }

        fn headerPrefixExists(prefix: []const u8) bool {
            for (known_prefixes) |p| {
                if (eqlName(prefix, p)) return true;
            }
            return false;
        }
    };
}

test "known_prefixes" {
    const S = HeaderSet(enum {
        @"alloca.h",
        @"sys/stat.h",
        @"sys/types.h",
        @"net/if.h",
        @"sys/sys/domain.h",
        @"foo/bar/baz.h",
    });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{
        "sys",
        "net",
        "sys/sys",
        "foo",
        "foo/bar",
    }), S.known_prefixes);
}

const builtin = @import("builtin");
const std = @import("std");
