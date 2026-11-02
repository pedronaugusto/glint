// The deferred `.?` with nothing writing the place after the guard.
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *usize) !void {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    defer out.* = found.?;
    if (line[0] == '#') found = 0;
}
