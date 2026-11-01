// review 4: rt/u_num2.zig
const std = @import("std");
const V = union(enum) { num: u32, none };
pub fn f(r: *std.Io.Reader) !u32 {
    const v: V = .{ .num = try r.takeInt(u32, .little) };
    return v.num + 1;
}
