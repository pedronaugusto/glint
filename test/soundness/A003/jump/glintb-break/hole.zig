// glint-b: A003 jump (break): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, n: u32) !void {
    const file = try dir.openFile(io, "a", .{});
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i == 3) return;
    }
    file.close(io);
}
