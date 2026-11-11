//! The uses left of `Facts.Named.orNull` and `Governed.Declared.orNull`, which read an unknown
//! declaration as none. Each is to become a switch that makes `.unknown` undecided where it
//! decides; the count recorded here only falls, and at none both go.
const std = @import("std");

/// The uses there may be, at most. Lower it with each site converted; never raise it.
const recorded = 2;

test "the uses of orNull only fall" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, "orNull_test.zig")) continue;
        const bytes = try entry.dir.readFileAlloc(io, entry.basename, a, .limited(16 << 20));
        defer a.free(bytes);
        count += std.mem.count(u8, bytes, ".orNull(");
    }
    if (count > recorded) {
        std.debug.print("{d} uses of orNull, above the {d} recorded: a new use reads unknown as none; switch on the Named instead\n", .{ count, recorded });
        return error.TestUnexpectedResult;
    }
    if (count < recorded) {
        std.debug.print("{d} uses of orNull, below the {d} recorded: lower `recorded` in src/orNull_test.zig to {d}\n", .{ count, recorded, count });
        return error.TestUnexpectedResult;
    }
}
