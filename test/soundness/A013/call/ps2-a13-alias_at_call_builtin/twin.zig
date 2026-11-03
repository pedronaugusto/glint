// pre-sweep-2 A013 twin: the same, called on what no input reaches.
const std = @import("std");
const check = std.debug.assert;
fn other(b: bool) void {
    _ = b;
}

pub fn f(r: *std.Io.Reader, n: u8) !u8 {
    const line = try r.take(4);
    @call(.auto, check, .{n > 3});
    return line[0];
}
