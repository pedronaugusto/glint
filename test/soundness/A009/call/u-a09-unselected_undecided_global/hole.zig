// matrix A009 call: input stored into a variable of a file the run does not select, then a constant passed to its function whose loop that variable bounds through a call A009 does not follow there: undecided at the call, not clean
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u64 {
    w.limit = try r.takeByte();
    return w.spin(3);
}
