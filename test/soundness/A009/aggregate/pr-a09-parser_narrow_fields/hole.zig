// A009 precision (precision-0.8, held): the same parser filling the pair from a full 32-bit word:
// a loop over it counts what a peer chose.
const std = @import("std");
const aegis = @import("aegis");
const Wide = struct { both: [2]u32 };
fn readWide(_: void, in: []const u8) error{Short}!Wide {
    if (in.len < 8) return error.Short;
    const w = @as(u32, in[0]) << 24 | @as(u32, in[1]) << 16 | @as(u32, in[2]) << 8 | in[3];
    return .{ .both = .{ in[3], w } };
}
pub fn f(r: *std.Io.Reader) !usize {
    const t = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, readWide);
    var n: usize = t.both[1];
    var steps: usize = 0;
    while (n > 0) : (n -= 1) steps += 1;
    return steps;
}
