// consolidate: a number from input handed to a function of a file the run does not select
// (dep.zig), which repeats a write as often as its integer parameter says, that parameter's
// type an integer in every build (u32 or u64): must flag (a choice of integer types read as no
// integer left the loop repeating by nothing)
const std = @import("std");
const dep = @import("dep.zig");
pub fn f(r: *std.Io.Reader, w: *std.Io.Writer) !void {
    const n = try r.takeInt(u32, .little);
    try dep.fill(w, n);
}
