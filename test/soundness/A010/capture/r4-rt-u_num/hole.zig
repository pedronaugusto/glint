// review 4: rt/u_num.zig
const std = @import("std");
const V = union(enum) { num: u32, none };
pub fn f(r: *std.Io.Reader) !u32 {
    const v: V = .{ .num = try r.takeInt(u32, .little) };
    switch (v) {
        .num => |x| return x + 1,
        .none => return 0,
    }
}
