// glint-b: a `.?` of a field under `!= null`, no call or write between
const std = @import("std");
const Search = struct { found: ?usize };
pub fn f(r: *std.Io.Reader, s: *Search) !usize {
    const line = try r.take(16);
    s.found = std.mem.indexOfScalar(u8, line, '\n');
    if (s.found != null) return s.found.? + 1;
    return 0;
}
