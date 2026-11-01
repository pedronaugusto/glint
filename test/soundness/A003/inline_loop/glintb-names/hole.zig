// glint-b: A003 inline_loop (names): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    inline for (.{ "a", "b" }) |name| {
        const file = try dir.openFile(io, name, .{});
        _ = file;
    }
}
