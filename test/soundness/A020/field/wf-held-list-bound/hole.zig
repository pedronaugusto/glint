// warp-fast: a list of Io values holds one (`list.items`): the loop runs as
// long as input says, with no cancellation point.
const std = @import("std");
const S = struct { list: std.ArrayList(std.Io) = .empty, n: usize = 0 };
pub fn f(s: *S, r: *std.Io.Reader) !void {
    const n = try r.takeInt(u32, .little);
    var i: u32 = 0;
    while (i < n) : (i += 1) s.n += 1;
}
