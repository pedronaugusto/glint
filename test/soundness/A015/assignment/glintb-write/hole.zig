// glint-b: A015 assignment (write): the unsafe shape, which must flag
const std = @import("std");
const File = std.Io.File;
fn Box(comptime T: type) type {
    return struct {
        v: T,
        pub fn put(b: *@This(), v: T) void {
            b.v = v;
        }
        pub fn deinit(b: *@This(), io: std.Io) void {
            b.v.close(io);
        }
    };
}
pub const Held = Box(File);
