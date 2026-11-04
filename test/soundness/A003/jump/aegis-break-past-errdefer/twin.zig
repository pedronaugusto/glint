// A003 jump (break): a file released on every path out of its block, a break out of the loop
// included, with an errdefer for the error after
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, n: u32) !void {
    blk: {
        const file = try dir.openFile(io, "a", .{});
        errdefer file.close(io);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (i == 3) {
                file.close(io);
                break :blk;
            }
        }
        file.close(io);
    }
}
