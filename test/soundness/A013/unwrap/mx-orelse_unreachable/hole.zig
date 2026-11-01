// matrix: orelse unreachable on what a search of a peer's bytes finds
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    return std.mem.indexOfScalar(u8, line, '\n') orelse unreachable;
}
