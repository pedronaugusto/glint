// review 6: fp/h01b_holder_assign_store.zig
const std = @import("std");
const Ops = struct { peek: *const fn (*std.Io.Writer) []u8, n: u32 };
fn none(w: *std.Io.Writer) []u8 {
    _ = w;
    return &.{};
}
fn hand(w: *std.Io.Writer) []u8 {
    return w.buffer;
}
var ops: Ops = .{ .peek = none, .n = 0 };
// arm stores hand, which gives back the writer's buffer: the read after reads what nothing wrote.
pub fn arm() void {
    ops.peek = hand;
}
pub fn main() !u8 {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("ab");
    const s = ops.peek(&w);
    return s[10];
}
