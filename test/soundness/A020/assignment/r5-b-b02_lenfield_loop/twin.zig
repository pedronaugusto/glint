// review 5: b/b02_lenfield_loop.zig
const std = @import("std");
const Header = struct { len: u32 };
pub fn f(r: *std.Io.Reader, out: *u32) !void {
    const h: Header = .{ .len = try r.takeInt(u32, .little) };
    var i: u32 = 0;
    while (i < h.len) : (i += 1) out.* +%= 1;
}
