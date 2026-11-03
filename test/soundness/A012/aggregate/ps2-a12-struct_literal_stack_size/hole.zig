// std's Thread.spawn maps a thread stack of config.stack_size bytes: a peer's number in a typed
// struct literal reads clean (the literal holds its fields by their declarations); via a var it is undecided
const std = @import("std");
fn work() void {}
pub fn f(r: *std.Io.Reader) !std.Thread {
    const n = try r.takeInt(u32, .little);
    return std.Thread.spawn(.{ .stack_size = n }, work, .{});
}
