// review 5: b/b13b_assign_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var v: u64 = 5;
    const n: u64 = try r.takeInt(u64, .little);
    v = n;
    return v * 1000;
}
