// warp-fast: a list of numbers holds no Io: the list type's fields read with
// its call's bindings (`T` = u32), not as the template's unknown `[]T`.
const std = @import("std");
const S = struct { list: std.ArrayList(u32) = .empty, n: usize = 0 };
pub fn f(s: *S, r: *std.Io.Reader) !void {
    const n = try r.takeInt(u32, .little);
    var i: u32 = 0;
    while (i < n) : (i += 1) s.n += 1;
}
