// matrix A013 call: input passed to a function of a file the run does not select, which asserts on it
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !void {
    const n = try r.takeByte();
    w.check(n);
}
