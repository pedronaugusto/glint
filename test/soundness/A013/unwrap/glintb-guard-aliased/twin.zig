// glint-b: a `.?` under `!= null`, a pointer to the place taken but nothing written between
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    const at = &found;
    if (found != null) return found.?;
    at.* = null;
    return 0;
}
