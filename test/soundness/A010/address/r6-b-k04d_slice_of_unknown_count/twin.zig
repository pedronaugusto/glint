// review 6: b/k04d_slice_of_unknown_count.zig
const std = @import("std");
// Memory of a type not read (anytype): its slice's length is not shown held.
pub fn f(io: std.Io, r: *std.Io.Reader, p: anytype, out: *u8) !void {
    _ = io;
    const n: usize = try r.takeInt(u32, .little);
    const s = p[0..n];
    var i: usize = 0;
    while (i < s.len) : (i += 1) out.* +%= s[i];
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn sum(io: std.Io, r: *std.Io.Reader, p: [*]const u8, out: *u8) !void {
    try f(io, r, p, out);
}
