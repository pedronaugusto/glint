// review 6: a20/e31_point_in_errdefer.zig
const std = @import("std");
fn step(t: *u64) !void {
    t.* +%= 1;
}
// The point is in an errdefer: it runs only when the pass fails, never on a pass that goes on.
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        errdefer io.checkCancel() catch {};
        try step(&t);
    }
    return t;
}
