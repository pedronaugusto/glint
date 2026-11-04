// A003 jump (break): a file whose only release on a break out of its block is an errdefer,
// which a break never runs: the file leaks on that path
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, n: u32) !void {
    blk: {
        const file = try dir.openFile(io, "a", .{});
        errdefer file.close(io);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (i == 3) break :blk;
        }
        file.close(io);
    }
}
