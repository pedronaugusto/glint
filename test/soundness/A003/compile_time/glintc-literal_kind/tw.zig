// An import of the case's, not selected: a generic that acquires through a function its argument gives, behind a comptime test of the argument's type (the twin's: std.meta.hasMethod, false for a literal, whose members are fields).
const std = @import("std");
pub fn run(context: anytype, dir: std.Io.Dir, io: std.Io) !void {
    if (comptime std.meta.hasMethod(@TypeOf(context), "make")) {
        const file = try context.make(dir, io);
        _ = file;
    }
}
