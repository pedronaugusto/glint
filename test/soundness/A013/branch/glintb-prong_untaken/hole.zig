// an else prong past the items a clamped subject can take: 8 is not an item, so input reaches the unreachable
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    return switch (@max(4, @min(b, 8))) {
        inline 4, 5, 6, 7 => |m| m,
        else => unreachable,
    };
}
