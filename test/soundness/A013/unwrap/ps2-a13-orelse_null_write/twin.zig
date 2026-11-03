// pre-sweep-2 A013 twin: `orelse 0`, never null.
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = std.mem.indexOfScalar(u8, line, ' ') orelse 0;
    return found.?;
}
