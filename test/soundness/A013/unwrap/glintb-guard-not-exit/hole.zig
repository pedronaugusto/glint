// glint-b: a `.?` after `if (x == null)` whose body goes on: the place may be null
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    var missing: usize = 0;
    if (found == null) missing += 1;
    return found.? + missing;
}
