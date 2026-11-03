// A010: @call given a tuple variable: fill writes the peer's number through the tuple's pointer, which then overflows
const std = @import("std");
fn fill(out: *u64, r: *std.Io.Reader) !void {
    out.* = try r.takeInt(u64, .little);
}
pub fn f(r: *std.Io.Reader) !u64 {
    var n: u64 = 0;
    const args = .{ &n, r };
    try @call(.auto, fill, args);
    return n * 3;
}
