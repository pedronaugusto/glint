// review 6: a20/e06_io_errunion_param.zig
const std = @import("std");
pub fn spin(io: anyerror!std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    if (io) |_| {} else |_| {}
    return t;
}
