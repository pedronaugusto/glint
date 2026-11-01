// glint-b: A015 destructure (tuple): the same shape made safe, which must stay clean
const std = @import("std");
const File = std.Io.File;
fn Box(comptime T: type) type {
    return struct {
        v: T,
        n: u32,
        pub fn count(b: *@This()) void {
            b.n, _ = .{ 1, b.v };
        }
    };
}
pub const Held = Box(File);
