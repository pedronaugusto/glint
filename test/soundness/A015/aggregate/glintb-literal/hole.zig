// glint-b: A015 aggregate (literal): the unsafe shape, which must flag
const std = @import("std");
const File = std.Io.File;
fn Pair(comptime T: type) type {
    return struct { both: struct { T, u32 } };
}
pub fn f(dir: std.Io.Dir, io: std.Io) !Pair(File) {
    return .{ .both = .{ try dir.openFile(io, "a", .{}), 1 } };
}
