// matrix A009 call: input stored into a variable of a file the run does not select, then a constant passed to its function indexing by that variable: undecided at the call, not clean
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u8 {
    w.at = try r.takeByte();
    return w.pick(0);
}
