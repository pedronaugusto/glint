// glint-b: a `.?` under `!= null` on what a search of a peer's bytes finds, nothing written between
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found != null) return found.?;
    found = null;
    return 0;
}
