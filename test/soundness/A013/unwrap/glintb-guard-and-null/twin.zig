// glint-b: a `.?` in the else of `if (x == null)`, and of the payload of `if (x) |_|`
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    if (found) |_| return found.?;
    return if (found == null) 0 else found.?;
}
