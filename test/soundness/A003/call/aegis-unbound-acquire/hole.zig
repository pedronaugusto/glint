// aegis (warp-fast's probe): a public generic acquires through its type parameter; nothing in the program binds it, so it is judged at its consumers' bindings.
const std = @import("std");
pub fn touch(comptime T: type, dir: std.Io.Dir, io: std.Io) !void {
    const f = try T.openFile(dir, io, "x", .{});
    _ = f;
}
