// glint-b: a `.?` under `!= null`, the place written between: another search of a peer's bytes
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found != null) {
        found = std.mem.indexOfScalar(u8, line, '\r');
        return found.?;
    }
    return 0;
}
