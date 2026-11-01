// review 6: fp/h01c_holder_none_only.zig
const std = @import("std");
const Ops = struct { peek: *const fn (*std.Io.Writer) []u8, n: u32 };
fn none(w: *std.Io.Writer) []u8 {
    _ = w;
    return &.{};
}
var ops: Ops = .{ .peek = none, .n = 0 };
// Safe: the only function stored hands back nothing.
pub fn main() !u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("ab");
    const s = ops.peek(&w);
    return if (s.len > 10) s[10] else 0;
}
