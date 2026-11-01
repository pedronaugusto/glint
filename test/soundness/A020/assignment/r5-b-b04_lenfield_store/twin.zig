// review 5: b/b04_lenfield_store.zig
const std = @import("std");
const Buf = struct { len: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    var b: Buf = .{ .len = 0 };
    if (b.len > 10) return 0;
    b.len = try r.takeInt(u64, .little);
    return b.len * 1000;
}
