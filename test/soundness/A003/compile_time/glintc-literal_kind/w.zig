// An import of the case's, not selected: a generic that acquires through a function its argument gives, behind a comptime test of the argument's type (the hole's: its kind, true for an anonymous struct).
const std = @import("std");
pub fn run(context: anytype, dir: std.Io.Dir, io: std.Io) !void {
    if (comptime @typeInfo(@TypeOf(context)) == .@"struct") {
        const file = try context.make(dir, io);
        _ = file;
    }
}
