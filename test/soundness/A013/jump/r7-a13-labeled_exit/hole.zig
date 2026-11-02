// A `.?` after a guard whose body ends in `return` but leaves its own labeled block early:
// the break falls through to the read with the place null.
const std = @import("std");
pub fn f(r: *std.Io.Reader, strict: bool) !usize {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) blk: {
        if (!strict) break :blk;
        return error.NoNewline;
    }
    return found.?;
}
