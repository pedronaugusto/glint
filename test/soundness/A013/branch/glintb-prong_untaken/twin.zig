// an else prong past the items a clamped subject can take: every value from 4 to 7 is an item, so no path takes it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    return switch (@max(4, @min(b, 7))) {
        inline 4, 5, 6, 7 => |m| m,
        else => unreachable,
    };
}
