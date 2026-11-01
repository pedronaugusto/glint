// review 5: b/b01b_lenfield_base.zig
const std = @import("std");
const Header = struct { size: u64 };
pub fn f(r: *std.Io.Reader) !u64 {
    const h: Header = .{ .size = try r.takeInt(u64, .little) };
    return h.size + 1;
}
