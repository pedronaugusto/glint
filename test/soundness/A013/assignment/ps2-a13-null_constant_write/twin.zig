// pre-sweep-2 A013 twin: the constant is a number.
const std = @import("std");
const nothing = 0;
pub fn f(r: *std.Io.Reader) !usize {
    const line = try r.take(16);
    var found = std.mem.indexOfScalar(u8, line, '\n');
    if (found == null) return error.NoNewline;
    if (line[0] == '#') found = nothing;
    return found.?;
}
