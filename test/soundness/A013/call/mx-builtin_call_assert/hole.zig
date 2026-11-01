// matrix: std's assert called through @call with a condition on input
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const b = try r.takeByte();
    @call(.auto, std.debug.assert, .{b < 4});
    return b;
}
