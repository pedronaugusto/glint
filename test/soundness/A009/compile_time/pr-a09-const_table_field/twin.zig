// A009 precision (precision-0.8, held): a field of a constant the compiler evaluates holds the
// constant's value, not what a decoder stores in a field of that type elsewhere: the loop over
// the table's offset counts what the program fixed.
const std = @import("std");
const Range = struct { offset: u32, extra: u5 };
const table = blk: {
    var r: [4]Range = undefined;
    for (&r, 0..) |*x, i| x.* = .{ .offset = @intCast(i * 8), .extra = 2 };
    break :blk r;
};
fn distance(r: *std.Io.Reader) !Range {
    const n = try r.takeInt(u32, .little);
    return .{ .offset = n, .extra = 3 };
}
pub fn encode(code: u2) usize {
    var n: usize = table[code].offset;
    var steps: usize = 0;
    while (n > 0) : (n -= 1) steps += 1;
    return steps;
}
pub fn decode(r: *std.Io.Reader) !u32 {
    return (try distance(r)).extra;
}
