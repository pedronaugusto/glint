// A009 precision (precision-0.8, held): the decoder's own field holds the peer's number: the loop
// over it counts what a peer chose.
const std = @import("std");
const Range = struct { offset: u32, extra: u5 };
fn distance(r: *std.Io.Reader) !Range {
    const n = try r.takeInt(u32, .little);
    return .{ .offset = n, .extra = 3 };
}
pub fn decode(r: *std.Io.Reader) !usize {
    var n: usize = (try distance(r)).offset;
    var steps: usize = 0;
    while (n > 0) : (n -= 1) steps += 1;
    return steps;
}
