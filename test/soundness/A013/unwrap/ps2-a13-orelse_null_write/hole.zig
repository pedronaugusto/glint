// pre-sweep-2 A013: a presence written whole with `opt orelse null` is read as never null, so the
// guard is kept; the lookup a peer's bytes choose gives null, and the `.?` meets it.
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = std.mem.indexOfScalar(u8, line, ' ') orelse null;
    return found.?;
}
