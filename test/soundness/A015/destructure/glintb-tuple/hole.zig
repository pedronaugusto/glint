// glint-b: A015 destructure (tuple): the unsafe shape, which must flag
const std = @import("std");
const File = std.Io.File;
fn Box(comptime T: type) type {
    return struct {
        v: T,
        n: u32,
        pub fn put(b: *@This(), v: T) void {
            b.v, b.n = .{ v, 1 };
        }
        pub fn deinit(b: *@This(), io: std.Io) void {
            b.v.close(io);
        }
    };
}
pub const Held = Box(File);
