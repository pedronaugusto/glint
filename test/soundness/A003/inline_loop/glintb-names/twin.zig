// glint-b: A003 inline_loop (names): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    inline for (.{ "a", "b" }) |name| {
        const file = try dir.openFile(io, name, .{});
        file.close(io);
    }
}
