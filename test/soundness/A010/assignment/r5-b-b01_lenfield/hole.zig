// review 5: b/b01_lenfield.zig
const std = @import("std");
const Header = struct { len: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    const h: Header = .{ .len = try r.takeInt(u64, .little) };
    return h.len + 1;
}
