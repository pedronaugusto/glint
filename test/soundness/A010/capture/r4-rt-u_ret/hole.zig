// review 4: rt/u_ret.zig
const std = @import("std");
const V = union(enum) { num: u32, none };
fn decode(r: *std.Io.Reader) !V {
    return .{ .num = try r.takeInt(u32, .little) };
}
pub fn f(r: *std.Io.Reader) !u32 {
    switch (try decode(r)) {
        .num => |x| return x + 1,
        .none => return 0,
    }
}
