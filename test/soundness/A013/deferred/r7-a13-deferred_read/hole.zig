// A `.?` in a `defer` after a guard: the defer runs at the block's end, after the write below
// it sets the place null, so the read a peer's bytes choose meets null.
const std = @import("std");
pub fn f(r: *std.Io.Reader, out: *usize) !void {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    defer out.* = found.?;
    if (line[0] == '#') found = null;
}
