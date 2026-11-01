// review 5: b/b02b_lenfield_loop_base.zig
const std = @import("std");
const Header = struct { size: u32 };
pub fn f(r: *std.Io.Reader, out: *u32) !void {
    const h: Header = .{ .size = try r.takeInt(u32, .little) };
    var i: u32 = 0;
    while (i < h.size) : (i += 1) out.* +%= 1;
}
