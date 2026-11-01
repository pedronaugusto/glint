// glint-b: A015 aggregate (literal): the same shape made safe, which must stay clean
const std = @import("std");
const File = std.Io.File;
fn Pair(comptime T: type) type {
    return struct { both: struct { *const T, u32 } };
}
pub fn f(held: *const File) Pair(File) {
    return .{ .both = .{ held, 1 } };
}
