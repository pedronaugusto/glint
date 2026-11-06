// matrix A009 call: input passed to a function of a file the run does not select, whose loop is bounded through a call A009 does not follow there: undecided at the call
const std = @import("std");
const w = @import("w.zig");
pub fn f(r: *std.Io.Reader) !u64 {
    const n = try r.takeByte();
    return w.spin(n);
}
