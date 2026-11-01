// review 4: rt/i_cast64.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const n: usize = @intCast(try r.takeInt(u64, .little));
    return n;
}
