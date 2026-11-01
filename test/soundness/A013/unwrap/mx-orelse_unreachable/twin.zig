// matrix: orelse unreachable on what a search of the program's own bytes finds
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    _ = try r.take(16);
    return std.mem.indexOfScalar(u8, "ab\n", '\n') orelse unreachable;
}
