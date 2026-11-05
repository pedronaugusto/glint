// matrix A013 call: the program's own value passed to that function, input read beside it
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !void {
    _ = try r.takeByte();
    w.check(3);
}
