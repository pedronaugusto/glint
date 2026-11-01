// matrix: what a search of a peer's bytes finds, its absence an error
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    return std.mem.indexOfScalar(u8, line, '\n') orelse error.NoNewline;
}
