// review 5: a09/d08_helper_predicate.zig
const std = @import("std");
fn below(i: u64, n: u64) bool {
    return i < n;
}
pub fn f(r: *std.Io.Reader, out: *u64) !void {
    const n = try r.takeInt(u64, .little);
    var i: u64 = 0;
    while (below(i, n)) : (i += 1) out.* +%= i;
}
