const std = @import("std");
const Io = std.Io;

pub fn replace(b: *std.Build, in_path: []const u8, replacements: []const []const u8) []const u8 {
    const arena = b.allocator;
    const io = b.graph.io;

    var map: std.StringHashMapUnmanaged(MapNode) = .{};
    for (replacements) |r| {
        const eq_index = std.mem.indexOfScalar(u8, r, '=') orelse errExit(
            "expected NAME=VALUE cmdline arg but got '{s}'",
            .{r},
        );
        map.put(arena, r[0..eq_index], .{ .count = 0, .value = r[eq_index + 1 ..] }) catch @panic("OOM");
    }

    const in = std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited) catch |e|
        std.debug.panic("open '{s}' failed with {t}", .{ in_path, e });

    const returnval = writeFile(in_path, in, &map, b) catch |err| std.debug.panic("replace failed with {t}", .{err});

    var unused_count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.count == 0) {
            std.log.err("unused variable '{s}'", .{entry.key_ptr.*});
            unused_count += 1;
        }
    }
    if (unused_count != 0) {
        std.log.err("{} unused variable(s), the did not appear in template '{s}'", .{ unused_count, in_path });
        std.process.exit(0xff);
    }

    return returnval;
}

const MapNode = struct {
    count: usize,
    value: []const u8,
};

fn writeFile(
    in_path: []const u8,
    in: []const u8,
    map: *const std.StringHashMapUnmanaged(MapNode),
    b: *std.Build,
) ![]const u8 {
    const alloc = b.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(b.allocator);

    var missing_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        const at_index = std.mem.indexOfScalarPos(u8, in, offset, '@') orelse break;
        try list.appendSlice(alloc, in[offset..at_index]);
        const end = std.mem.indexOfScalarPos(u8, in, at_index + 1, '@') orelse errExit(
            "{s}: unterminated '@' at offset {}",
            .{ in_path, at_index },
        );
        const name = in[at_index + 1 .. end];
        if (map.getEntry(name)) |entry| {
            entry.value_ptr.count += 1;
            try list.appendSlice(alloc, entry.value_ptr.value);
        } else {
            std.log.err("undefined variable '{s}'", .{name});
            try list.appendSlice(alloc, b.fmt("MISSING_VAR_{s}", .{name}));
            missing_count += 1;
        }
        offset = end + 1;
    }
    if (missing_count > 0) errExit("{} missing variable(s) for template '{s}'", .{ missing_count, in_path });
    return list.toOwnedSlice(alloc);
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
