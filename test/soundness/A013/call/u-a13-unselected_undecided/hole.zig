// matrix A013 call: input passed to a function of a file the run does not select, which takes std.debug.assert as a value: what it asserts is not read there, so the call is undecided, not clean
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !void {
    const n = try r.takeByte();
    w.check(n);
}
