// matrix A013 call: input passed to a function of that file that asserts nothing
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u8 {
    const n = try r.takeByte();
    return w.plain(n);
}
