// review 5: b/b12c_optcap_ptr_unknown.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, start: ?u64) !u64 {
    var o: ?u64 = start;
    const n: u64 = try r.takeInt(u64, .little);
    if (o) |*p| p.* = n;
    const v = o.?;
    return v * 1000;
}
