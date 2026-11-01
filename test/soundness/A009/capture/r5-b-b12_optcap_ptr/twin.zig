// review 5: b/b12_optcap_ptr.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var o: ?u64 = 5;
    const n: u64 = try r.takeInt(u64, .little);
    if (o) |*p| p.* = n;
    const v = o.?;
    return v * 1000;
}
