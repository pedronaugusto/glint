// review 6: fp/f00_param_ops.zig
const std = @import("std");
pub const Ops = struct { fill: *const fn (*[4]u8) void };
fn use(b: []const u8) void {
    std.debug.print("{any}\n", .{b});
}
// Baseline: ops comes from the caller, the call reaches what no store here shows.
pub fn run(ops: Ops) void {
    var buf: [4]u8 = undefined;
    ops.fill(&buf);
    use(&buf);
}
