// glint-b: a `.?` under `!= null`, the place written through a pointer to it between
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    const at = &found;
    if (found != null) {
        at.* = std.mem.indexOfScalar(u8, line, '\r');
        return found.?;
    }
    return 0;
}
