// glint-b: a `.?` after `== null) return`, in a loop that writes the place after it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    var total: usize = 0;
    while (total < 4) : (total += 1) {
        total += found.?;
        found = std.mem.indexOfScalar(u8, line[total..], '\n');
    }
    return total;
}
