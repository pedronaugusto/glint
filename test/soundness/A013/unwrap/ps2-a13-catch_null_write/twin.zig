// pre-sweep-2 A013 twin: the write gives a number on failure, never null.
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = std.fmt.parseInt(usize, line[1..4], 10) catch 0;
    return found.?;
}
