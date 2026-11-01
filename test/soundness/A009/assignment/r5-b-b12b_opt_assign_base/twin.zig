// review 5: b/b12b_opt_assign_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var o: ?u64 = 5;
    const n: u64 = try r.takeInt(u64, .little);
    o = n;
    const v = o.?;
    return v * 1000;
}
