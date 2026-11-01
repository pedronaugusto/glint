// glint-b: A003 branch (select): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, k: u8) !void {
    const file = try dir.openFile(io, "a", .{});
    switch (k) {
        0 => file.close(io),
        else => file.close(io),
    }
}
