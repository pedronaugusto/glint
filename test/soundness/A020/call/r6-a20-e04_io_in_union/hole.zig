// review 6: a20/e04_io_in_union.zig
const std = @import("std");
const Mode = union(enum) { live: std.Io, off };
pub fn spin(m: Mode, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    _ = m;
    return t;
}
