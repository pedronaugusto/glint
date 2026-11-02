// glint-b: a `.?` of a field under `!= null`, a call between that may write it through its pointer
const std = @import("std");
const Search = struct {
    found: ?usize,
    fn again(s: *Search, line: []const u8) void {
        s.found = std.mem.indexOfScalar(u8, line, '\r');
    }
};
pub fn f(r: *std.Io.Reader, s: *Search) !usize {
    const line = try r.take(16);
    s.found = std.mem.indexOfScalar(u8, line, '\n');
    if (s.found != null) {
        s.again(line);
        return s.found.?;
    }
    return 0;
}
