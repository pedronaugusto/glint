// A009 precision (precision-0.8, held): a parser's array-literal and optional result fields, each
// built from two bytes: the parser shows each number's range, so a loop over one counts no more
// than a short's count.
const std = @import("std");
const aegis = @import("aegis");
const Table = struct { pair: [2]u32, compressed: ?u32 };
fn readTable(_: void, in: []const u8) error{Short}!Table {
    if (in.len < 8) return error.Short;
    return .{
        .pair = .{ in[3], @as(u32, in[4]) << 8 | in[5] },
        .compressed = if (in[0] == 0) null else @as(u32, in[1]) << 8 | in[2],
    };
}
pub fn f(r: *std.Io.Reader) !usize {
    const t = try aegis.input.Untrusted([]const u8).init(try r.take(8)).parse({}, readTable);
    var n: usize = t.pair[1];
    var m: usize = t.compressed orelse 0;
    var steps: usize = 0;
    while (n > 0) : (n -= 1) steps += 1;
    while (m > 0) : (m -= 1) steps += 1;
    return steps;
}
