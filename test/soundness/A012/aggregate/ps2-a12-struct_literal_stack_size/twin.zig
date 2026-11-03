// the stack size is the program's constant
const std = @import("std");
fn work() void {}
pub fn f(r: *std.Io.Reader) !std.Thread {
    const n = try r.takeInt(u32, .little);
    _ = n;
    return std.Thread.spawn(.{ .stack_size = 64 * 1024 }, work, .{});
}
