const std = @import("std");
fn fill(out: *u64, r: *std.Io.Reader) !void {
    _ = r;
    out.* = 7;
}
pub fn f(r: *std.Io.Reader) !u64 {
    var n: u64 = 0;
    try @call(.auto, fill, .{ &n, r });
    return n * 3;
}
