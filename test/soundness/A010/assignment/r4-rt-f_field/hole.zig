// review 4: rt/f_field.zig
const std = @import("std");
const S = struct { num: u32, other: u32 };
pub fn f(r: *std.Io.Reader) !u32 {
    const v: S = .{ .num = try r.takeInt(u32, .little), .other = 0 };
    return @field(v, "num") + 1;
}
