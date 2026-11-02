// glint-b: a `.?` after `== null) return`, in a loop that writes something else
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    const found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    var total: usize = 0;
    while (total < 4) : (total += 1) total += found.?;
    return total;
}
