// pre-sweep-2 A013: a presence written whole with a constant holding `null` is read as never null
// (`null` resolves as a scalar), so the guard is kept; the `.?` meets null on the path a peer's
// byte chooses.
const std = @import("std");
const nothing = null;
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = nothing;
    return found.?;
}
