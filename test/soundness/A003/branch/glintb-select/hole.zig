// glint-b: A003 branch (select): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, k: u8) !void {
    const file = try dir.openFile(io, "a", .{});
    switch (k) {
        0 => file.close(io),
        else => {},
    }
}
