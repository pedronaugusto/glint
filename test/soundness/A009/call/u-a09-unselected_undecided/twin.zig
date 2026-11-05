// matrix A009 call: input passed to a function of that file that loops on nothing
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u64 {
    const n = try r.takeByte();
    return w.idle(n);
}
