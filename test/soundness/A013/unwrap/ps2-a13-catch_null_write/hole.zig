// pre-sweep-2 A013: a presence written whole with `x catch null` is read as never null (Facts
// reads the `catch`'s value as the payload, `null` a scalar), so the guard is kept; a peer's bytes
// that fail to parse make the place null, and the `.?` meets it.
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = std.fmt.parseInt(usize, line[1..4], 10) catch null;
    return found.?;
}
