// A `.?` after a guard whose every path leaves the function.
const std = @import("std");
pub fn f(r: *std.Io.Reader, strict: bool) !usize {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) {
        if (!strict) return 0;
        return error.NoNewline;
    }
    return found.?;
}
