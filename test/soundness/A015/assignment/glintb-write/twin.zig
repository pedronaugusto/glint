// glint-b: A015 assignment (write): the same shape made safe, which must stay clean
const std = @import("std");
const File = std.Io.File;
fn Box(comptime T: type) type {
    return struct {
        v: T,
        pub fn get(b: *const @This()) T {
            return b.v;
        }
    };
}
pub const Held = Box(File);
